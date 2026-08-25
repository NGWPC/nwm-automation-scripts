import glob
import os
import re
import shutil
import tarfile
import subprocess
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
from pathlib import Path

import ecflow

from ecf_task_mgr.constants import AoiType, LogFileType, SavedStateType, SubtaskType
from ecf_task_mgr.ecf_interface import EcflowConnection, EcflowInterface

from run_paths import RunPaths
from ecf_task_mgr.tasks import Task

def touch_file_if_not_exists(file_path: str) -> None:
    """
    Create a file if it does not already exist.

    Args:
        file_path (str): Path to the file to create.
    """
    try:
        path = Path(file_path)
        if not path.exists():
            # Create the file without overwriting existing ones
            path.touch(exist_ok=False)
            print(f"File '{file_path}' created successfully.")
        else:
            print(f"File '{file_path}' already exists.")
    except PermissionError:
        print(f"Permission denied: Cannot create '{file_path}'.")
    except FileNotFoundError:
        print(f"Invalid path: Directory for '{file_path}' does not exist.")
    except OSError as e:
        print(f"OS error while creating '{file_path}': {e}")


class NWMForecast(ABC):
    """Abstract base for an NWM realtime run.

    Holds all configuration, path, ecFlow, and container-execution logic shared
    by every NWM configuration. Concrete subclasses implement the run-specific
    pieces: :class:`AnalysisAssim` for the two-pass analysis-assimilation
    configurations (standard AnA and Extended AnA, both driven by `--lookback`
    windows) and :class:`Forecast` for the forward forecast configurations
    (Short Range, Medium Range).
    """

    # Configuration names
    CONFIG_ANA = "AnA"
    CONFIG_SHORT_RANGE = "Short_Range"
    CONFIG_MEDIUM_RANGE = "Medium_Range"
    CONFIG_EXT_ANA = "Extended_AnA"

    # Domain names
    DOMAIN_CONUS = "CONUS"
    DOMAIN_HAWAII = "Hawaii"
    DOMAIN_ALASKA = "Alaska"
    DOMAIN_PUERTO_RICO = "Puerto_Rico"

    # Forecast lengths in hours; negative means backward analysis (end=T0, start=T0+length)
    _FORECAST_LENGTHS = {
        "AnA": -3,
        "Short_Range": 18,
        "Medium_Range": 240,  # 10 days
        "Extended_AnA": -28,
    }

    # CASETYPE identifiers derived from (config, domain)
    _CASE_TYPES = {
        ("AnA", "CONUS"): "CONUS_ANALYSIS_ASSIM",
        ("Short_Range", "CONUS"): "CONUS_SHORT_RANGE",
        ("Extended_AnA", "CONUS"): "CONUS_EXT_ANALYSIS_ASSIM",
    }

    def __init__(self, config_name: str, domain: str, t0: datetime,
                 package_dir: str, working_dir: str, comout: str,
                 previous_day_comout: str, vpu: str | None = None,
                 hydrofab_file: str | None = None,
                 form_assign_file: str | None = None,
                 cat_grp_file: str | None = None,
                 gageid: str = "01123000",
                 nprocs: int = 2):
        if config_name not in self._FORECAST_LENGTHS:
            raise ValueError(f"Unknown config_name: {config_name}")
        if domain not in (self.DOMAIN_CONUS, self.DOMAIN_HAWAII,
                          self.DOMAIN_ALASKA, self.DOMAIN_PUERTO_RICO):
            raise ValueError(f"Unknown domain: {domain}")
        if form_assign_file is None:
            raise ValueError("form_assign_file is required for regionalization runs.")
        if cat_grp_file is None:
            raise ValueError("cat_grp_file is required for regionalization runs.")

        self.config_name = config_name
        self.domain = domain
        self.t0 = t0
        self.package_dir = package_dir
        self.working_dir = working_dir
        self.comout = comout
        self.previous_day_comout = previous_day_comout
        self.forecast_length = self._FORECAST_LENGTHS[config_name]
        self.vpu = vpu
        self.hydrofab_file = hydrofab_file
        self.form_assign_file = form_assign_file
        self.cat_grp_file = cat_grp_file
        self.gageid = gageid
        # Number of processors this run uses: fed to the RTE `-n` arg and used by
        # NWMRunner as the scheduling weight (sum of concurrent runs' nprocs must
        # not exceed the system processor count).
        self.nprocs = nprocs
        # Comma-separated core IDs this run is pinned to (docker --cpuset-cpus),
        # assigned by NWMRunner before the run. Empty = no pinning.
        self.cpuset = ""
        # Per-pass outcomes for two-pass (Extended AnA) runs, set during runRTE /
        # ext_ana_restart and read by NWMRunner to record pass1/pass2 in the job
        # status file. None until the pass runs; "succeed" or "failed" after.
        self.pass1_status = None
        self.pass2_status = None

        ecf_name = os.getenv("ECF_NAME")
        if not ecf_name:
          print("ECF_NAME is not set — are you running inside an ecFlow job?")
          raise RuntimeError("ECF_NAME not found on the server.")

        ecf_tryno= int(os.environ["ECF_TRYNO"])
        ecf_pass= os.environ["ECF_PASS"]
        ecf_rid = os.getenv("ECF_RID")

        conn = EcflowConnection( f"{package_dir}/ush/nwm-realtime/ecflow-settings.json" )
        self.task = Task(
             conn=conn,
             ecf_task_path=ecf_name,
             ecf_tryno=ecf_tryno,
             ecf_pass=ecf_pass,
             ecf_rid=ecf_rid,
        )

    # ------------------------------------------------------------------ #
    # Factory
    # ------------------------------------------------------------------ #

    @classmethod
    def create(cls, config_name: str, domain: str, t0: datetime,
               package_dir: str, working_dir: str, comout: str,
               previous_day_comout: str, vpu: str | None = None,
               hydrofab_file: str | None = None,
               form_assign_file: str | None = None,
               cat_grp_file: str | None = None,
               gageid: str = "01123000",
               nprocs: int = 2) -> "NWMForecast":
        """Build the concrete NWMForecast subclass appropriate for config_name.

        Returns an :class:`AnalysisAssim` for AnA/Extended_AnA and a
        :class:`Forecast` for Short_Range/Medium_Range.
        """
        # Deferred imports to avoid a circular dependency (subclasses import this
        # module for the base class).
        from nwm_analysis_assim import AnalysisAssim
        from forecast import Forecast

        if config_name in (cls.CONFIG_ANA, cls.CONFIG_EXT_ANA):
            subcls = AnalysisAssim
        elif config_name in (cls.CONFIG_SHORT_RANGE, cls.CONFIG_MEDIUM_RANGE):
            subcls = Forecast
        else:
            raise ValueError(f"No NWMForecast subclass for config_name: {config_name}")

        return subcls(
            config_name=config_name,
            domain=domain,
            t0=t0,
            package_dir=package_dir,
            working_dir=working_dir,
            comout=comout,
            previous_day_comout=previous_day_comout,
            vpu=vpu,
            hydrofab_file=hydrofab_file,
            form_assign_file=form_assign_file,
            cat_grp_file=cat_grp_file,
            gageid=gageid,
            nprocs=nprocs,
        )

    # ------------------------------------------------------------------ #
    # Derived paths (mirrors $USHnwm and $PARMnwm from the ex-script)
    # ------------------------------------------------------------------ #

    @property
    def ush_dir(self) -> str:
        return os.path.join(self.package_dir, "ush")

    @property
    def parm_dir(self) -> str:
        return os.path.join(self.package_dir, "parm")

    @property
    def case_type(self) -> str | None:
        """CASETYPE identifier derived from (config_name, domain)."""
        return self._CASE_TYPES.get((self.config_name, self.domain))

    @property
    def hydrofab_arg(self) -> str:
        """`--hydrofab_file` option (with leading space) pointing at the gage's
        hydrofabric gpkg. Empty when no hydrofabric is set."""
        if not self.hydrofab_file:
            return ""
        return f' --hydrofab_file "{self.hydrofab_file}"'

    @property
    def output_format_arg(self) -> str:
        return ' --output_format NetCDF'

    @property
    def form_assign_arg(self) -> str:
        """`-faf` option (with leading space). Empty when no formulation
        assignment file is set."""
        if not self.form_assign_file:
            return ""
        return f' -faf "{self.form_assign_file}"'

    @property
    def cat_grp_arg(self) -> str:
        """`-cgf` option (with leading space). Empty when no catchment group
        file is set."""
        if not self.cat_grp_file:
            return ""
        return f' -cgf "{self.cat_grp_file}"'

    # ------------------------------------------------------------------ #
    # Forecast window helpers
    # ------------------------------------------------------------------ #

    @property
    def start_time(self) -> datetime:
        if self.forecast_length < 0:
            return self.t0 + timedelta(hours=self.forecast_length)
        return self.t0

    @property
    def end_time(self) -> datetime:
        if self.forecast_length < 0:
            return self.t0
        return self.t0 + timedelta(hours=self.forecast_length)

    # ------------------------------------------------------------------ #
    # VPU region/run_id helper
    # ------------------------------------------------------------------ #

    @property
    def vpu_arg(self) -> str:
        return f' --vpu {self.vpu}' if self.vpu else ""

    @property
    def run_id(self) -> str:
        """Unique identifier for run - VPU or gage ID"""
        return self.vpu if self.vpu else self.gageid

    def _paths(self, formulation_dir: str = None, working_dir: str = None,
               run_id: str = None) -> RunPaths:
        """RunPaths resolver for this run's regionalization directory.

        Defaults to (working_dir, _formulation_dir, run_id); pass overrides to
        name a run under a different root (e.g. a previous failed working_dir) or
        a formulation dir computed locally by a caller."""
        return RunPaths(
            self.working_dir if working_dir is None else working_dir,
            self._formulation_dir if formulation_dir is None else formulation_dir,
            self.run_id if run_id is None else run_id,
        )

    # ------------------------------------------------------------------ #
    # Subclass-specific hooks used by shared code (configureRTE)
    # ------------------------------------------------------------------ #

    @property
    @abstractmethod
    def _formulation_dir(self) -> str:
        """Regionalization sub-directory name for this configuration
        (e.g. 'region_ana', 'region_extended_ana', 'default_short')."""

    @abstractmethod
    def _state_save_src(self) -> str:
        """Host path of the warm-state directory to seed this run from."""

    # ------------------------------------------------------------------ #
    # configureRTE  (mirrors exnwm.sh lines 39-48)
    # ------------------------------------------------------------------ #

    def configureRTE(self) -> None:
        rte_dir = os.path.join(self.ush_dir, "nwm-rte")

        shutil.copy(os.path.join(rte_dir, "config.bashrc"), self.working_dir)
        shutil.copy(os.path.join(rte_dir, "run.sh"), self.working_dir)

        # shutil.copytree(os.path.join(rte_dir, "logs"), os.path.join(self.working_dir, "logs"), dirs_exist_ok=True)
        os.makedirs(f"{self.working_dir}/logs", exist_ok=True)
        os.makedirs(f"{self.working_dir}/logs/rte", exist_ok=True)
        os.makedirs(f"{self.working_dir}/logs/docker", exist_ok=True)
        os.makedirs(f"{self.working_dir}/logs/ngen", exist_ok=True)

        config_bashrc = os.path.join(self.working_dir, "config.bashrc")
        with open(config_bashrc) as f:
            content = f.read()
        content = re.sub(
            r"^MNT__RUN_NGEN__HOST=.*$",
            f"MNT__RUN_NGEN__HOST={self.working_dir}",
            content, flags=re.MULTILINE,
        )
        content = re.sub(
            r"^MNT__MODULE_PARAM_FILES_DIR__HOST=.*$",
            f"MNT__MODULE_PARAM_FILES_DIR__HOST={self.parm_dir}",
            content, flags=re.MULTILINE,
        )
        content = re.sub(
            r"^REPOS_COMMON_ROOT__HOST=.*$",
            f"REPOS_COMMON_ROOT__HOST={self.package_dir}/ush",
            content, flags=re.MULTILINE,
        )
        with open(config_bashrc, "w") as f:
            f.write(content)

        run_sh = os.path.join(self.working_dir, "run.sh")
        with open(run_sh) as f:
            content = f.read()
        bin_mounted = os.path.join(rte_dir, "bin_mounted")
        content = content.replace("$(pwd)/bin_mounted", bin_mounted)
        # Inject an optional --cpuset-cpus flag into `docker run` so NWMRunner can
        # pin each region's container to specific cores via the CPUSET_CPUS env
        # var. `${CPUSET_CPUS:+...}` (safe under `set -u`) expands to nothing when
        # the var is unset/empty, preserving the un-pinned default.
        ulimit_line = "--ulimit nofile=100000:100000 \\\n"
        cpuset_line = '        ${CPUSET_CPUS:+--cpuset-cpus="${CPUSET_CPUS}"} \\\n'
        if ulimit_line in content and "CPUSET_CPUS" not in content:
            content = content.replace(ulimit_line, ulimit_line + cpuset_line)
        else:
            print(
                "WARNING: could not inject --cpuset-cpus into run.sh "
                "(anchor missing or already present); core pinning disabled.",
                flush=True,
            )
        with open(run_sh, "w") as f:
            f.write(content)

        paths = self._paths()
        dst_state_save = paths.host(f"{self.run_id}_state_save")
        src_state_save = self._state_save_src()
        src_tar = f"{src_state_save}.tar"
        print( "src_tar = ", src_tar )
        if os.path.isfile(src_tar):
           tar_file = os.path.basename(src_tar)
           dst_state_save_tar = paths.host(tar_file)
           dst_path = paths.host()
           try: 
              os.makedirs(dst_path, exist_ok=True)
           except Exception as e:
              print( e )
              sys.exit(1)

           print( "dst_stat_save_tar = ", dst_state_save_tar )
           shutil.copy( src_tar, dst_state_save_tar )
           # Open the tar file in read mode
           with tarfile.open(dst_state_save_tar, 'r') as tar:
              # Extract state files
              tar.extractall( path=dst_state_save) 
        #
        # Copy RFC reservoir output timeseries
        #
        rfc_path = os.path.join(self.comout, "rfc_timeseries")
        working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
        if os.path.isdir( rfc_path ) and any(os.scandir(rfc_path)):
            shutil.copytree( rfc_path, working_rfc_path, dirs_exist_ok=True )
        else:
            print("WARNING: RFC Reservoir timeseries does not exist or is empty! Skipping reservoir data assimilation!")

        # Copy the previous day RFC reservoir output timeseries
        if self.start_time.hour <= 6 or self.start_time.date() < self.t0.date():
           rfc_path = os.path.join(self.previous_day_comout, "rfc_timeseries")
           working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
           if os.path.isdir( rfc_path ) and any(os.scandir(rfc_path)):
                shutil.copytree( rfc_path, working_rfc_path, dirs_exist_ok=True )
           else:
                print("WARNING: Previous RFC Reservoir timeseries does not exist or is empty!")

        #
        # Copy USGS output timeslices
        #
        usgs_path = os.path.join(self.comout, "usgs_timeslices")
        working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
        if os.path.isdir( usgs_path ) and any(os.scandir(usgs_path)):
            shutil.copytree( usgs_path, working_usgs_path, dirs_exist_ok=True )
        else:
            print("WARNING: USGS timeslices does not exist or is empty! Skipping USGS data assimilation!")

        # Copy the previous day USGS output timeslices
        if self.start_time.hour <= 6 or self.start_time.date() < self.t0.date():
           usgs_path = os.path.join(self.previous_day_comout, "usgs_timeslices")
           working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
           if os.path.isdir( usgs_path ) and any(os.scandir(usgs_path)):
                shutil.copytree( usgs_path, working_usgs_path, dirs_exist_ok=True )
           else:
                print("WARNING: Previous day USGS timeslices does not exist or is empty!")

    # ------------------------------------------------------------------ #
    # ecFlow / container helpers  (shared by all configurations)
    # ------------------------------------------------------------------ #

    @staticmethod
    def _lookback_minutes(window_hours: int) -> int:
        """Convert a desired simulated AnA window length (hours) into the forcing
        template `LookBack` value (minutes) expected by RTE's `--lookback` option.
        msw-mgr computes the simulated window as `LookBack/60 - 1` hours, so
        `LookBack = (window_hours + 1) * 60`."""
        return (window_hours + 1) * 60

    @staticmethod
    def _is_restart(ecfcon: EcflowConnection) -> bool:
        """
        Check the EcFlow server to decide if it is a new job or a restart job
        """
        workdir = NWMForecast._pre_workdir(ecfcon)

        return True if workdir != "NONE" else False

    @staticmethod
    def _pre_workdir(ecfcon: EcflowConnection) -> str:
        """
        Get the working directgory of the previous failed job
        """
        ecf_name = os.getenv("ECF_NAME")
        if not ecf_name:
          print("ECF_NAME is not set — are you running inside an ecFlow job?")
          raise RuntimeError("ECF_NAME not found on the server.")

        ecfintf = EcflowInterface(ecfcon)
        workdir = ecfintf.var_fetch( ecf_name, "PRE_WORKDIR" )
        return workdir

    @staticmethod
    def _pass1or2(ecfcon: EcflowConnection) -> int | None:
        """
        Check the EcFlow server to decide if it is restart from pass 1
        or 2.
        """
        ecf_name = os.getenv("ECF_NAME")
        if not ecf_name:
          print("ECF_NAME is not set — are you running inside an ecFlow job?")
          raise RuntimeError("ECF_NAME not found on the server.")

        ecfintf = EcflowInterface(ecfcon)
        try:
           pass_num = ecfintf.var_fetch( self.task.ecf_path, "PASS" )
        except Exception as e:
           return None

        return pass_num

    @staticmethod
    def _set_ecf_var( ecfcon: EcflowConnection,  name: str, value: str  ) -> None:
        """
        set the PRE_WORKDIR variable
        """
        ecf_name = os.getenv("ECF_NAME")
        if not ecf_name:
          print("ECF_NAME is not set — are you running inside an ecFlow job?")
          raise RuntimeError("ECF_NAME not found on the server.")

        ecfintf = EcflowInterface(ecfcon)
        ecfintf.var_set( ecf_name, name, value )

    def _docker_env(self) -> dict:
        """Environment for docker_run subprocesses. Exports CPUSET_CPUS so run.sh
        pins this run's container to the assigned cores (empty = no pinning). Set
        per-call, so parallel regions each get their own cpuset safely."""
        env = os.environ.copy()
        env["CPUSET_CPUS"] = self.cpuset or ""
        return env

    def _docker_run(self, docker_args: str) -> int:
        """Run a single RTE invocation inside the container; return its exit code."""
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run python -um "ngen_rte.run_regionalization_standalone" {docker_args}'
        print( "docker run command: ", cmd )
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _docker_move_dir(self, src: str, dst: str) -> int:
        """rename a directory; return its exit code."""
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run mv {src} {dst}'
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _docker_copy_dir(self, src: str, dst: str) -> int:
        """copy a directory recursively inside the container; return its exit code."""
        #cmd = f'source run.sh && docker_run mkdir -p {dst}'
        #result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run cp -r {src} {dst}'
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _docker_mkdir(self, dir: str) -> int:
        """create a directory; return its exit code."""
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run mkdir -p {dir}'
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _docker_exec(self, args: str) -> int:
        """Run an arbitrary command inside the container (as root); return its exit
        code. `docker_run` runs the command directly (no shell), so shell globs are
        not expanded — use `find ... -name '<glob>'` for wildcard matching."""
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run {args}'
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _container_path(self, host_path: str) -> str:
        """Map a host path under working_dir to its in-container path (working_dir
        is bind-mounted at /ngwpc/run_ngen)."""
        return self._paths().to_container(host_path)

    def _docker_restart(self, src: str, dst: str, checkpoint_dir: str) -> int:
        """Resume a single RTE invocation from an earlier stopped point inside the container; return its exit code."""
        cmd = f'function sudo {{ "$@"; }}; source run.sh && docker_run python -um "ngen_rte.run_restart" -src {src} -dst {dst} --checkpoint_dir {checkpoint_dir}'
        print( "docker run command: ", cmd )
        result = subprocess.run(["bash", "-c", cmd], cwd=self.working_dir, env=self._docker_env())
        return result.returncode

    def _mount_failed_workdir(self, working_dir: str) -> None:
        """Insert a bind mount of the previous failed job's working directory at
        /ngwpc/run_ngen_failed into the copied run.sh, so a restart run can read
        the failed run's checkpoints and outputs."""
        run_sh_path = os.path.join(self.working_dir, "run.sh")
        with open(run_sh_path) as f:
            content = f.read()
        content = re.sub(
            r'(-v "\$\{MNT__RUN_NGEN__HOST\}:\$\{MNT__RUN_NGEN__CONTAINER\}" \\)',
            lambda m: m.group(1) + f'\n        -v "{working_dir}:{RunPaths.RUN_NGEN_FAILED}" \\',
            content,
        )
        with open(run_sh_path, "w") as f:
            f.write(content)

    def _archive_run_outputs(self, run_dir: str, end_time: datetime) -> int:
        """Rename the run's Output, logs, and Input directories to timestamped
        names (<name>_<ts>) and copy state_save to state_save_<ts>, where <ts> is
        the simulation end time in %Y%m%d%H format. Preserves each pass's results
        before the next pass overwrites them.

        RTE writes these directories inside the container as root, so the host
        user cannot rename/create entries under run_dir. All operations are done
        in-container (mv/cp) where they run as root."""
        ts = end_time.strftime("%Y%m%d%H")
        c_run_dir = self._container_path(run_dir)
        #don't archive Input dir
        #for name in ("Output", "logs", "Input"):
        for name in ("Output", "logs"):
            src = os.path.join(run_dir, name)
            if os.path.isdir(src):
                rc = self._docker_move_dir(
                    os.path.join(c_run_dir, name),
                    os.path.join(c_run_dir, f"{name}_{ts}"),
                )
                if rc != 0:
                    print(f"ERROR: Failed to rename {src} -> {name}_{ts} (rc={rc})", flush=True)
                    return 1
                print(f"INFO: Renamed {src} -> {name}_{ts}", flush=True)
            else:
                print(f"WARNING: Cannot rename missing directory: {src}", flush=True)
                return 1

        name = "state_save"
        src = os.path.join(run_dir, name)
        if os.path.isdir(src):
            tarcmd = f"tar -C {c_run_dir}/{name} -cf {c_run_dir}/{name}_{ts}.tar ./"
            print( tarcmd )
            #rc = self._docker_copy_dir(
            #    os.path.join(c_run_dir, name),
            #    os.path.join(c_run_dir, f"{name}_{ts}"),
            #)
            rc = self._docker_exec( tarcmd )
            if rc != 0:
                print(f"ERROR: Failed to archive {src} -> {name}_{ts}.tar (rc={rc})", flush=True)
                return 1
            print(f"INFO: Archived {src} -> {name}_{ts}.tar", flush=True)
        else:
            print(f"WARNING: Cannot archive missing directory: {src}", flush=True)
            return 1
        return 0

    # ------------------------------------------------------------------ #
    # Output staging helpers (shared by move_outputs_to_storage overrides)
    # ------------------------------------------------------------------ #

    def _storage_dirs(self) -> tuple:
        """Return (run_dir, dst, dst_logs) for this region and create the two
        COMOUT destination directories. Products go to
        {comout}/{cyc}/{case_type}/{run_id}/ and logs to
        {comout}/logs/{cyc}/{case_type}/{run_id}/, where cyc is T0's hour."""
        cyc = self.t0.strftime("%H")
        run_dir = self._paths().host_run_dir
        dst = os.path.join(self.comout, cyc, self.case_type, self.run_id)
        dst_logs = os.path.join(self.comout, "logs", cyc, self.case_type, self.run_id)
        os.makedirs(dst, exist_ok=True)
        os.makedirs(dst_logs, exist_ok=True)
        return run_dir, dst, dst_logs

    def _store_ngen_logs(self, run_dir: str, dst_logs: str) -> None:
        """Copy the run dir's top-level NGen *.log files into dst_logs (shared by
        the `_store_logs` overrides)."""
        for f in glob.glob(os.path.join(run_dir, "*.log")):
            shutil.copy2(f, dst_logs)

    def _store_mswm_logs(self, dst_logs: str) -> None:
        """Copy the shared MSWM logs tree (working_dir/logs) into dst_logs (shared
        by the `_store_logs` overrides)."""
        mswm_logs = os.path.join(self.working_dir, "logs")
        if os.path.isdir(mswm_logs):
            shutil.copytree(mswm_logs, dst_logs, dirs_exist_ok=True)

    @staticmethod
    def _store_file(src: str, dst_path: str) -> int:
        """Copy a single output file; return 0 on success, 1 if missing."""
        if os.path.isfile(src):
            shutil.copy2(src, dst_path)
            print(f"INFO: Stored {src} -> {dst_path}", flush=True)
            return 0
        print(f"ERROR: Missing output file: {src}", flush=True)
        return 1

    @staticmethod
    def _store_tree(src: str, dst_dir: str) -> int:
        """Copy a directory (e.g. a warm-state dir) under dst_dir keeping its
        basename; return 0 on success, 1 if missing."""
        if os.path.isdir(src):
            dst = os.path.join(dst_dir, os.path.basename(src))
            shutil.copytree(src, dst, dirs_exist_ok=True)
            print(f"INFO: Stored {src} -> {dst}", flush=True)
            return 0
        print(f"ERROR: Missing warm-state directory: {src}", flush=True)
        return 1

    @staticmethod
    def _is_empty_or_missing(folder_path):
        """
        Returns True if the folder is empty or does not exist.
        Returns False if the folder exists and is not empty.
        """
        # If folder doesn't exist
        if not os.path.exists(folder_path):
            return True

        # If it's not a directory, treat as empty
        if not os.path.isdir(folder_path):
            return True

        # Check if directory has any entries
        try:
            with os.scandir(folder_path) as entries:
                for _ in entries:  # Found something
                    return False
            return True  # No entries found
        except PermissionError:
            # If we can't access it, treat as not empty
            return False

    # ------------------------------------------------------------------ #
    # Run entry points (implemented per configuration)
    # ------------------------------------------------------------------ #

    @abstractmethod
    def runRTE(self) -> int:
        """Run this configuration from scratch; return the final exit code."""

    @abstractmethod
    def runRTE_restart(self, working_dir: str, pass_num: int) -> int:
        """Restart this configuration from a previously failed run; return the
        final exit code."""

    @abstractmethod
    def move_outputs_to_storage(self) -> int:
        """Copy this region's RTE products/logs/warm-states from the working
        directory into COMOUT under {comout}/{cyc}/{case_type}/{run_id}/. Return
        0 on success, 1 if a required product is missing. Use the _storage_dirs /
        _store_logs / _store_file / _store_tree helpers."""

    @abstractmethod
    def _store_logs(self, run_dir: str, dst_logs: str) -> None:
        """Copy this configuration's logs into dst_logs. Implementations differ:
        Forecast has a single un-archived run (top-level *.log + MSWM tree);
        AnalysisAssim additionally copies each pass's archived logs_<ts>
        directory. Build on _store_ngen_logs / _store_mswm_logs."""
