import os
import shutil
from datetime import datetime, timedelta

from ecf_task_mgr.ecf_interface import EcflowConnection, EcflowInterface

from nwm_forecast import NWMForecast


class AnalysisAssim(NWMForecast):
    """Two-pass analysis-assimilation configurations: standard AnA and Extended
    AnA. Both split their analysis window into two consecutive `--lookback`
    chunks with a state handoff between passes."""

    def _ana_state_save_src(self) -> str:
        """Return the source state_save path for CONUS_ANALYSIS_ASSIM warm start.
        The AnA cycle runs hourly; warm states come from the previous cycle (T0-1h).
        The state_save timestamp is the analysis window start time (self.start_time = T0-3h).
        Uses previous_day_comout when T0-1h rolls back to the previous day.
        When the analysis window start time (T0-3h) is 16z, prefers the Extended AnA
        state_save from that cycle; falls back to the AnA state_save with a warning
        if that directory is not found."""
        t_cyc = self.t0 - timedelta(hours=1)
        cyc = t_cyc.strftime("%H")
        ts = self.start_time.strftime("%Y%m%d%H")
        base_comout = self.previous_day_comout if t_cyc.date() < self.t0.date() else self.comout
        ana_dir = "CONUS_ANALYSIS_ASSIM"
        ext_ana_dir = "CONUS_EXT_ANALYSIS_ASSIM"
        default_path = os.path.join(base_comout, cyc, ana_dir, self.run_id, f"state_save_{ts}")

        # At cycle 19z, use the Exteneded restart which is 16z
        if cyc == "18": # 18z = 19z - 1
            #uses the 16z restart from extended AnA
            ext_path = os.path.join(base_comout, "16", ext_ana_dir, self.run_id, f"state_save_{ts}")
            ext_ana_state_tar = f"{ext_path}.tar"
            if os.path.isfile(ext_ana_state_tar):
                return ext_path
            print(
                f"WARNING: CONUS_EXT_ANALYSIS_ASSIM warm states {ext_ana_state_tar} are missing "
                f"(cyc={cyc}, T0={self.t0:%Y-%m-%d %H:%M:%S}); "
                f"using warm states from {ana_dir} case type instead.",
                flush=True,
            )

        return default_path

    def _ext_ana_state_save_src(self) -> str:
        """Return the source state_save path for CONUS_EXT_ANALYSIS_ASSIM warm start.
        The Extended AnA window starts at T0 - 28h (previous day 12z), so the warm
        state is the timestamped state_save valid at that start time
        (state_save_<start %Y%m%d%H>) from the previous day's 12z folder. Prefers
        CONUS_EXT_ANALYSIS_ASSIM; falls back to CONUS_ANALYSIS_ASSIM with a warning
        if the preferred directory is not found. The caller is responsible for
        checking whether the returned path exists; if it does not, a cold start
        should be used."""
        cyc = "16" # use 16z here because the 12z restart file is saved in the 16z
                   # folder - Extended AnA runs at 16z cycle
        ts = self.start_time.strftime("%Y%m%d%H")
        ana_dir = "CONUS_ANALYSIS_ASSIM"
        ext_ana_dir = "CONUS_EXT_ANALYSIS_ASSIM"
        primary_path = os.path.join(
            self.previous_day_comout, cyc, ext_ana_dir, self.run_id, f"state_save_{ts}"
        )
        ext_ana_state_tar = f"{primary_path}.tar"
        if os.path.isfile(ext_ana_state_tar):
            return primary_path
        print(
            f"WARNING: {ext_ana_dir} warm states {ext_ana_state_tar} are missing at "
            f"{self.start_time:%Y-%m-%d %H:%M:%S} (T0={self.t0:%Y-%m-%d %H:%M:%S}); "
            f"using warm states from {ana_dir} case type instead.",
            flush=True,
        )
        return os.path.join(
                #the standard AnA restart file is saved in the 12z folder 
            self.previous_day_comout, "12", ana_dir, self.run_id, f"state_save_{ts}"
        )

    # ------------------------------------------------------------------ #
    # Subclass-specific hooks used by NWMForecast.configureRTE
    # ------------------------------------------------------------------ #

    @property
    def _formulation_dir(self) -> str:
        if self.case_type == "CONUS_EXT_ANALYSIS_ASSIM":
            return "region_extended_ana"
        return "region_ana"

    def _state_save_src(self) -> str:
        if self.case_type == "CONUS_EXT_ANALYSIS_ASSIM":
            return self._ext_ana_state_save_src()
        return self._ana_state_save_src()

    # ------------------------------------------------------------------ #
    # Two-pass analysis run
    # ------------------------------------------------------------------ #

    def _run_two_pass_ana(self, case_type: str, fconfig: str, rname: str,
                          src_state_save: str, window_hours: tuple,
                          extra_args: str = "",
                          run1_checkpoint_interval: int = None) -> int:
        """Run a two-pass AnA-type analysis, splitting the analysis window into
        two consecutive chunks with a state handoff.

        window_hours = (l1, l2): simulated window length (hours) of run 1 (the
        earlier chunk) and run 2 (the later chunk, ending at T0). Run 1 covers
        [T0-(l1+l2), T0-l2] and saves its end state; run 2 covers [T0-l2, T0],
        loading run 1's saved state. The window length is controlled per run via
        the RTE `--lookback` option (minutes). Returns the exit code of the first
        failing run, or of run 2 if both ran."""
        l1, l2 = window_hours
        # Host run directory; working_dir is mounted at /ngwpc/run_ngen in the container.
        if case_type == "CONUS_ANALYSIS_ASSIM":
            formulation_dir = "region_ana"
        elif case_type == "CONUS_EXT_ANALYSIS_ASSIM":
            formulation_dir = "region_extended_ana"
        else:
            print(
                f"ERROR: {case_type} unknown."
                f"exited with return code 1",
                flush=True,
            )
            return 1

        paths = self._paths(formulation_dir=formulation_dir)
        run_dir = paths.host_run_dir
        # Container path where RTE writes/reads the saved model state
        # (the run directory inside the /ngwpc/run_ngen mount).
        state_save_dir = paths.container(f"{self.run_id}_state_save")

        # Run 1 initial states: load previous-cycle warm states if present, else cold start.
        src_state_save_tar = f"{src_state_save}.tar"
        if os.path.isfile(src_state_save_tar):
            print(
                f"INFO: Warm states found: {src_state_save_tar}; "
                f"T0={self.t0}; {case_type} job will use warm states.",
                flush=True,
            )
            load_state_arg = f' --load_state_from "{state_save_dir}"'
        else:
            print(
                f"WARNING: state_save directory not found: {src_state_save_tar}; "
                f"T0={self.t0}; {case_type} job will use cold start.",
                flush=True,
            )
            load_state_arg = ""

        # Run 1: earlier chunk, ends at T0 - l2, window l1 hours; saves its end state.
        dt1 = (self.t0 - timedelta(hours=l2)).strftime("%Y-%m-%d %H:%M:%S")
        checkpoint_arg = f" --checkpoint_interval {run1_checkpoint_interval}" if run1_checkpoint_interval is not None else ""
        docker_args = (
            f'-n {self.nprocs} -fconfig "{fconfig}" -dt "{dt1}" --lookback {self._lookback_minutes(l1)} '
            f'--save_state -rname "{rname}"{extra_args}{load_state_arg}{checkpoint_arg}{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}'
            f'{self.output_format_arg}'
        )
        working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
        if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
            docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
        else:
            print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

        working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
        if os.path.isdir( working_usgs_path ) and any(os.scandir(working_usgs_path)):
            docker_args += f' -usgs {os.path.join(paths.container_run_dir, "usgs_timeslices")}'
        else:
            print("WARNING: UGS timeslices not found! Skipping streamflow data assimilation!")

        rc = self._docker_run(docker_args)
        if rc is None or rc != 0:
            print(
                f"ERROR: {case_type} run 1 (T0={dt1}, lookback={l1}h) "
                f"exited with return code {rc}, re-try one more time ...",
                flush=True,
            )
            # Try again
            if case_type == "CONUS_ANALYSIS_ASSIM":
               rc = self._docker_run(docker_args)
            elif case_type == "CONUS_EXT_ANALYSIS_ASSIM":
               src_dir = paths.container_run_dir
               rc_move = self._docker_move_dir( src_dir, f"{src_dir}_failed" )
               if rc_move != 0:
                  print(
                     f"ERROR: {case_type} run 1 (T0={dt1}, lookback={l1}h) "
                     f"renaming {src_dir} to {src_dir}_failed exited with return code {rc_move}",
                     flush=True,
                  )
                  self.pass1_status = "failed"
                  return rc_move
               dst_dir = paths.container_run_dir
               checkpoint_dir = os.path.join(f"{src_dir}_failed", "checkpoint" )
               if self._is_empty_or_missing( checkpoint_dir ):
                  rc = self._docker_run(docker_args)
               else:
                  rc = self._docker_restart( f"{src_dir}_failed", dst_dir, checkpoint_dir )
               if rc is None or rc != 0:
                   print(
                      f"ERROR: {case_type} run 1 (T0={dt1}, lookback={l1}h) "
                      f"re-try exited with return code {rc}",
                      flush=True,
                   )
                   self.pass1_status = "failed"
                   return rc

        # Run 1 complete.
        self.pass1_status = "succeed"

        # Preserve run 1's outputs before run 2 overwrites them (end time = T0 - l2).
        self._archive_run_outputs(run_dir, self.t0 - timedelta(hours=l2))

        # Clean up run 1 artifacts so run 2 starts with a fresh working directory.
        # RTE writes run_dir as root, so do this in-container (find/mkdir/touch run
        # as root); shell globs don't expand under docker_run, hence find -delete.
        c_run_dir = paths.container_run_dir
        self._docker_exec(f'find {c_run_dir} -maxdepth 1 -name "*.log" -delete')
        self._docker_exec(f'find {c_run_dir} -maxdepth 1 -name "*.json" -delete')
        self._docker_exec(f'mkdir -p {c_run_dir}/logs')
        self._docker_exec(f'touch {c_run_dir}/logs/msw_mgr_default.log')

        # Run 2: later chunk, ends at T0, window l2 hours; loads run 1's saved state.
        dt2 = self.t0.strftime("%Y-%m-%d %H:%M:%S")
        state_save_dir = paths.container(self.run_id, "state_save")
        docker_args = (
            f'-n {self.nprocs} -fconfig "{fconfig}" -dt "{dt2}" --lookback {self._lookback_minutes(l2)} '
            f'--save_state -rname "{rname}"{extra_args} --load_state_from "{state_save_dir}"{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}'
            f'{self.output_format_arg}'
        )
        working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
        if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
            docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
        else:
            print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

        working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
        if os.path.isdir( working_usgs_path ) and any(os.scandir(working_usgs_path)):
            docker_args += f' -usgs {os.path.join(paths.container_run_dir, "usgs_timeslices")}'
        else:
            print("WARNING: UGS timeslices not found! Skipping streamflow data assimilation!")

        rc = self._docker_run(docker_args)
        if rc is None or rc != 0:
            print(
                f"ERROR: {case_type} run 2 (T0={dt2}, lookback={l2}h) "
                f"exited with return code {rc}, re-try one more time ...",
                flush=True,
            )
            # Try again
            rc = self._docker_run(docker_args)
            if rc != 0:
                print(
                    f"ERROR: {case_type} run 2 (T0={dt1}, lookback={l1}h) "
                    f"re-try exited with return code {rc}",
                    flush=True,
                )
                self.pass2_status = "failed"
                return rc

        # Preserve run 2's outputs (end time = T0); its success gates the result.
        rc = self._archive_run_outputs(run_dir, self.t0)
        self.pass2_status = "failed" if (rc is None or rc != 0) else "succeed"
        return rc

    def ext_ana_restart(self, working_dir: str, pass_num: int,
                          run1_checkpoint_interval: int = None) -> int:
        """Resume a failed Extended AnA two-pass run.

        working_dir: host path of the job's working directory (mapped to
-            /ngwpc/run_ngen in the container).

        pass_num: 1 if pass 1 failed; 2 if pass 2 failed.

        Pass 1 failure: restarts pass 1 via _docker_restart, then runs pass 2
        normally via _docker_run.  Pass 2 failure: skips pass 1 entirely and
        runs pass 2 directly via _docker_run.
        """
        formulation_dir = "region_extended_ana"
        fconfig = "extended_ana"
        rname = "region_extended_ana"
        l1, l2 = 24, 4
        extra_args = " -nwmout"

        paths = self._paths(formulation_dir=formulation_dir)
        run_dir = paths.host_run_dir
        src_dir = paths.failed_container_run_dir
        dst_dir = paths.container_run_dir
        state_save_dir = paths.container(f"{self.run_id}_state_save")
        dt1 = (self.t0 - timedelta(hours=l2)).strftime("%Y-%m-%d %H:%M:%S")
        dt2 = self.t0.strftime("%Y-%m-%d %H:%M:%S")

        ecfcon = EcflowConnection( f"{self.package_dir}/ush/nwm-realtime/ecflow-settings.json" )
        previous_workdir = self._pre_workdir(ecfcon)

        # Run 1 initial states: load previous-cycle warm states if present, else cold start.
        src_state_save=self._ext_ana_state_save_src()
        src_state_save_tar = f"{src_state_save}.tar"
        if os.path.isfile(src_state_save_tar):
            print(
                f"INFO: Warm states found: {src_state_save}; "
                f"T0={self.t0}; {self.case_type} job will use warm states.",
                flush=True,
            )
            load_state_arg = f' --load_state_from "{state_save_dir}"'
        else:
            print(
                f"WARNING: state_save directory not found: {src_state_save}; "
                f"T0={self.t0}; {self.case_type} job will use cold start.",
                flush=True,
            )
            load_state_arg = ""

        if pass_num == 1:
            checkpoint_dir = os.path.join(src_dir, "checkpoint")
            # The failed run's checkpoint on the host (previous_workdir is what is
            # mounted at /ngwpc/run_ngen_failed for this restart).
            checkpoint_dir_host = self._paths(
                formulation_dir=formulation_dir, working_dir=previous_workdir
            ).host(self.run_id, "checkpoint")
            if self._is_empty_or_missing(checkpoint_dir_host):
               dt1 = (self.t0 - timedelta(hours=l2)).strftime("%Y-%m-%d %H:%M:%S")
               checkpoint_arg = f" --checkpoint_interval {run1_checkpoint_interval}" if run1_checkpoint_interval is not None else ""
               docker_args = (
               f'-n {self.nprocs} -fconfig "{fconfig}" -dt "{dt1}" --lookback {self._lookback_minutes(l1)} '
               f'--save_state -rname "{rname}"{extra_args}{load_state_arg}{checkpoint_arg}{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}'
               f'{self.output_format_arg}'
               )
               working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
               if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
                   docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
               else:
                   print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

               working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
               if os.path.isdir( working_usgs_path ) and any(os.scandir(working_usgs_path)):
                   docker_args += f' -usgs {os.path.join(paths.container_run_dir, "usgs_timeslices")}'
               else:
                   print("WARNING: UGS timeslices not found! Skipping streamflow data assimilation!")

               rc = self._docker_run(docker_args)
            else:
               rc = self._docker_restart(src_dir, dst_dir, checkpoint_dir)

            if rc is None or rc != 0:
                print(
                    f"ERROR: CONUS_EXT_ANALYSIS_ASSIM restart pass 1 (T0={dt1}, lookback={l1}h) "
                    f"exited with return code {rc}",
                    flush=True,
                )
                self.pass1_status = "failed"
                return rc

            self.pass1_status = "succeed"
            self._archive_run_outputs(run_dir, self.t0 - timedelta(hours=l2))

        if pass_num == 2:
            # Pass 1 succeeded in the previous job; carry that forward.
            self.pass1_status = "succeed"
            #ts = (self.t0 - timedelta(hours=l2)).strftime("%Y%m%d%H")
            #for name in ("Output", "state_save"):
            #   previous_dir_host =  f"{previous_workdir}/regionalization/{formulation_dir}/{self.run_id}"
            #   src = os.path.join(previous_dir_host, name)
            #   dst = os.path.join(run_dir, f"{name}_{ts}")
            #   if os.path.isdir(src):
            #      shutil.copytree(src, dst, dirs_exist_ok=True)
            #      print(f"INFO: Archived {src} -> {dst}", flush=True)
            #   else:
            #      print(f"ERROR: Cannot archive missing directory: {src}", flush=True)
            #      return 1

            #copy the previously failed directory to current working directory.
            formu_dir = paths.container()
            rc_mkdir = self._docker_mkdir(formu_dir)
            rc_copy = self._docker_copy_dir(src_dir, formu_dir)
            if rc_copy != 0:
                print(f"ERROR: Copying directory: {src_dir} to {formu_dir} failed! Return code = {rc_copy}.", flush=True)
                return 1

        state_save_dir = paths.container(self.run_id, "state_save")

        # Pass 2: run normally via _docker_run (not _docker_restart).
        docker_args = (
            f'-n {self.nprocs} -fconfig "{fconfig}" -dt "{dt2}" --lookback {self._lookback_minutes(l2)} '
            f'--save_state -rname "{rname}"{extra_args} --load_state_from "{state_save_dir}"'
            f'{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}'
            f'{self.output_format_arg}'
        )
        working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
        if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
            docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
        else:
            print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

        working_usgs_path = os.path.join(paths.host_run_dir, "usgs_timeslices")
        if os.path.isdir( working_usgs_path ) and any(os.scandir(working_usgs_path)):
            docker_args += f' -usgs {os.path.join(paths.container_run_dir, "usgs_timeslices")}'
        else:
            print("WARNING: UGS timeslices not found! Skipping streamflow data assimilation!")

        rc = self._docker_run(docker_args)
        if rc is None or rc != 0:
            print(
                f"ERROR: CONUS_EXT_ANALYSIS_ASSIM restart pass 2 (T0={dt2}, lookback={l2}h) "
                f"exited with return code {rc}, re-try one more time ...",
                flush=True,
            )
            rc = self._docker_run(docker_args)
            if rc is None or rc != 0:
                print(
                    f"ERROR: CONUS_EXT_ANALYSIS_ASSIM restart pass 2 (T0={dt2}, lookback={l2}h) "
                    f"re-try exited with return code {rc}",
                    flush=True,
                )
                self.pass2_status = "failed"
                return rc

        # Preserve pass 2's outputs (end time = T0); its success gates the result.
        rc = self._archive_run_outputs(run_dir, self.t0)
        self.pass2_status = "failed" if (rc is None or rc != 0) else "succeed"
        return rc

    def _store_logs(self, run_dir: str, dst_logs: str) -> None:
        """Two-pass run: each pass archives its logs as logs_<ts> (via
        _archive_run_outputs). Copy both passes' logs_<ts> directories, plus any
        top-level *.log and the shared MSWM logs tree."""
        self._store_ngen_logs(run_dir, dst_logs)
        l2 = 4 if self.case_type == "CONUS_EXT_ANALYSIS_ASSIM" else 2
        ts_t0 = self.t0.strftime("%Y%m%d%H")
        ts_r1 = (self.t0 - timedelta(hours=l2)).strftime("%Y%m%d%H")
        for ts in (ts_t0, ts_r1):
            logs_dir = os.path.join(run_dir, f"logs_{ts}")
            if os.path.isdir(logs_dir):
                shutil.copytree(logs_dir, os.path.join(dst_logs, f"logs_{ts}"), dirs_exist_ok=True)
                print(f"INFO: Stored {logs_dir} -> {os.path.join(dst_logs, f'logs_{ts}')}", flush=True)
            else:
                print(f"WARNING: Missing archived logs directory: {logs_dir}", flush=True)
        self._store_mswm_logs(dst_logs)

    def move_outputs_to_storage(self) -> int:
        """Store both passes' products: catchment/T-route NetCDF (renamed by
        simulation end time) and the warm-state directories, for run 1 (ends at
        T0-l2) and run 2 (ends at T0)."""
        run_dir, dst, dst_logs = self._storage_dirs()
        self._store_logs(run_dir, dst_logs)

        rc = 0
        l2 = 4 if self.case_type == "CONUS_EXT_ANALYSIS_ASSIM" else 2
        l1 = 24 if self.case_type == "CONUS_EXT_ANALYSIS_ASSIM" else 1
        ts_t0 = self.t0.strftime("%Y%m%d%H")
        ts_r1 = (self.t0 - timedelta(hours=l2)).strftime("%Y%m%d%H")
        #catchment and t-route files should be stamped at the beginning 
        #of the time period
        ts_r1_begin = (self.t0 - timedelta(hours=l2) -  timedelta(hours=l1)).strftime("%Y%m%d%H") 
        #for ts in (ts_t0, ts_r1):
        #    rc |= self._store_tree(os.path.join(run_dir, f"state_save_{ts}"), dst)

        for ts in (ts_t0, ts_r1):
            rc |= self._store_file(os.path.join(run_dir, f"state_save_{ts}.tar"), 
            os.path.join(dst, f"state_save_{ts}.tar") )

        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_t0}", "catchment_output.nc"),
            os.path.join(dst, f"catchment_output_{ts_r1}00.nc"),
        )
        ts_tr_r1 = (self.t0 - timedelta(hours=l2) - timedelta(hours=1)).strftime("%Y%m%d%H")
        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_t0}", f"troute_output_{ts_tr_r1}00.nc"),
            dst,
        )
        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_t0}", f"troute_lakeout_{ts_tr_r1}00.nc"),
            dst,
        )
        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_r1}", "catchment_output.nc"),
            os.path.join(dst, f"catchment_output_{ts_r1_begin}00.nc"),
        )
        ts_tr_r1_begin = (self.t0 - timedelta(hours=l2) -  timedelta(hours=l1) - timedelta(hours=1)).strftime("%Y%m%d%H") 
        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_r1}", f"troute_output_{ts_tr_r1_begin}00.nc"),
            dst,
        )
        rc |= self._store_file(
            os.path.join(run_dir, f"Output_{ts_r1}", f"troute_lakeout_{ts_tr_r1_begin}00.nc"),
            dst,
        )
        return rc

    # ------------------------------------------------------------------ #
    # Run entry points
    # ------------------------------------------------------------------ #

    def runRTE(self) -> int:
        case_type = self.case_type
        if case_type == "CONUS_ANALYSIS_ASSIM":
            # AnA 3h window split into 1h (run 1) + 2h (run 2).
            return self._run_two_pass_ana(
                case_type=case_type,
                fconfig="standard_ana",
                rname="region_ana",
                src_state_save=self._ana_state_save_src(),
                window_hours=(1, 2),
                extra_args=" -nwmout",
            )
        elif case_type == "CONUS_EXT_ANALYSIS_ASSIM":
            # Extended AnA 28h window split into 24h (run 1) + 4h (run 2).
            return self._run_two_pass_ana(
                case_type=case_type,
                fconfig="extended_ana",
                rname="region_extended_ana",
                src_state_save=self._ext_ana_state_save_src(),
                window_hours=(24, 4),
                extra_args=" -nwmout",
                run1_checkpoint_interval=1,
            )
        raise NotImplementedError(
            f"runRTE not implemented for config='{self.config_name}', domain='{self.domain}'"
        )

    def runRTE_restart(self, working_dir: str, pass_num: int) -> int:
        # NOTE: the caller (NWMRunner) must have already mounted working_dir at
        # /ngwpc/run_ngen_failed via _mount_failed_workdir (done once up front so
        # regions can restart in parallel without racing on run.sh).
        case_type = self.case_type
        if case_type == "CONUS_ANALYSIS_ASSIM":
            return self.runRTE()
        elif case_type == "CONUS_EXT_ANALYSIS_ASSIM":
            return self.ext_ana_restart(working_dir, pass_num, 1)
        raise NotImplementedError(
            f"runRTE_restart not implemented for config='{self.config_name}', domain='{self.domain}'"
        )
