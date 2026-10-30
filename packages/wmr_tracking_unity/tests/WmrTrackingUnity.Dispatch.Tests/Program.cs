using System;
using OnyxLens.WmrTrackingUnity.Dispatch;
using OnyxLens.WmrTrackingUnity.Stereo;

namespace OnyxLens.WmrTrackingUnity.Dispatch.Tests
{
    internal static class Program
    {
        private static int _checks;
        private static int _failures;

        private static int Main()
        {
            ParsesOnlyTheContractVendorNames();
            StartRequiresVendorOrPriorConfigure();
            ConfigureSelectsWithoutStarting();
            StartMaySelectADifferentVendorWhileIdle();
            RunningVendorRejectsSwitchesUntilStop();
            RepeatedStartIsIdempotent();
            StopKeepsSelectionForRestart();
            DisposeClearsSelection();
            RecenterRequiresARunningVendor();
            UnknownCommandAndVendorAreRejected();
            StartFailureKeepsSelectionButNotRunning();
            StereoModeNamesMatchTheUnityEnum();

            Console.WriteLine(
                _failures == 0
                    ? $"PASS: {_checks} dispatch checks"
                    : $"FAIL: {_failures} of {_checks} dispatch checks failed"
            );
            return _failures == 0 ? 0 : 1;
        }

        private static void ParsesOnlyTheContractVendorNames()
        {
            CheckParse("viture", true, VendorBackend.Viture);
            CheckParse("VITURE", true, VendorBackend.Viture);
            CheckParse("  xreal\t", true, VendorBackend.Xreal);
            CheckParse("XREAL", true, VendorBackend.Xreal);
            CheckParse("", false, VendorBackend.None);
            CheckParse("   ", false, VendorBackend.None);
            CheckParse("air2ultra", false, VendorBackend.None);
            CheckParse("auto", false, VendorBackend.None);

            Check(
                VendorNames.ToWireName(VendorBackend.Viture) == "viture",
                "wire name viture"
            );
            Check(
                VendorNames.ToWireName(VendorBackend.Xreal) == "xreal",
                "wire name xreal"
            );
            Check(
                VendorNames.ToWireName(VendorBackend.None) == string.Empty,
                "wire name none is empty"
            );
        }

        private static void CheckParse(
            string value,
            bool expectedOk,
            VendorBackend expectedBackend
        )
        {
            bool ok = VendorNames.TryParse(value, out VendorBackend backend);
            Check(
                ok == expectedOk && backend == expectedBackend,
                $"parse '{value}' => {expectedOk}/{expectedBackend} (got {ok}/{backend})"
            );
        }

        private static void StartRequiresVendorOrPriorConfigure()
        {
            var dispatch = new VendorRelayDispatch();
            RelayDecision decision = dispatch.Decide("start", null);
            Check(decision.IsRejected, "start without vendor is rejected");
            Check(decision.ErrorCode == "protocol", "start without vendor is protocol");
            Check(!dispatch.IsRunning, "rejected start does not run");
            Check(
                dispatch.SelectedVendor == VendorBackend.None,
                "rejected start does not select"
            );
        }

        private static void ConfigureSelectsWithoutStarting()
        {
            var dispatch = new VendorRelayDispatch();
            RelayDecision configure = dispatch.Decide("configure", "viture");
            Check(
                configure.Kind == RelayCommandKind.Configure &&
                configure.Target == VendorBackend.Viture,
                "configure targets viture"
            );
            dispatch.Accepted(configure);
            Check(
                dispatch.SelectedVendor == VendorBackend.Viture,
                "configure selects viture"
            );
            Check(!dispatch.IsRunning, "configure does not start viture");

            RelayDecision start = dispatch.Decide("start", null);
            Check(
                start.Kind == RelayCommandKind.Start &&
                start.Target == VendorBackend.Viture,
                "start without vendor uses configured viture"
            );
        }

        private static void StartMaySelectADifferentVendorWhileIdle()
        {
            var dispatch = new VendorRelayDispatch();
            dispatch.Accepted(dispatch.Decide("configure", "viture"));

            RelayDecision start = dispatch.Decide("start", "xreal");
            Check(
                start.Kind == RelayCommandKind.Start &&
                start.Target == VendorBackend.Xreal,
                "start vendor field overrides idle configuration"
            );
            dispatch.Accepted(start);
            Check(
                dispatch.RunningVendor == VendorBackend.Xreal,
                "xreal is running"
            );
            Check(
                dispatch.SelectedVendor == VendorBackend.Xreal,
                "xreal replaces the selection"
            );
        }

        private static void RunningVendorRejectsSwitchesUntilStop()
        {
            var dispatch = new VendorRelayDispatch();
            Start(dispatch, "viture");

            RelayDecision switchStart = dispatch.Decide("start", "xreal");
            Check(switchStart.IsRejected, "start other vendor while running is rejected");
            Check(switchStart.ErrorCode == "busy", "running switch is busy");

            RelayDecision switchConfigure = dispatch.Decide("configure", "xreal");
            Check(
                switchConfigure.IsRejected,
                "configure other vendor while running is rejected"
            );
            Check(switchConfigure.ErrorCode == "busy", "running configure is busy");
            Check(
                dispatch.RunningVendor == VendorBackend.Viture &&
                dispatch.SelectedVendor == VendorBackend.Viture,
                "rejected switches leave viture selected and running"
            );

            RelayDecision sameVendorConfigure = dispatch.Decide("configure", "VITURE");
            Check(
                sameVendorConfigure.Kind == RelayCommandKind.Configure &&
                sameVendorConfigure.Target == VendorBackend.Viture,
                "same-vendor configure while running is accepted"
            );
        }

        private static void RepeatedStartIsIdempotent()
        {
            var dispatch = new VendorRelayDispatch();
            Start(dispatch, "viture");

            RelayDecision repeated = dispatch.Decide("start", "viture");
            Check(
                repeated.Kind == RelayCommandKind.Start &&
                repeated.Target == VendorBackend.Viture,
                "repeated start stays on viture"
            );

            RelayDecision repeatedWithoutVendor = dispatch.Decide("start", null);
            Check(
                repeatedWithoutVendor.Kind == RelayCommandKind.Start &&
                repeatedWithoutVendor.Target == VendorBackend.Viture,
                "repeated start without vendor stays on viture"
            );
        }

        private static void StopKeepsSelectionForRestart()
        {
            var dispatch = new VendorRelayDispatch();
            Start(dispatch, "xreal");

            RelayDecision stop = dispatch.Decide("stop", null);
            Check(
                stop.Kind == RelayCommandKind.Stop &&
                stop.Target == VendorBackend.Xreal,
                "stop targets the running vendor"
            );
            dispatch.Accepted(stop);
            Check(!dispatch.IsRunning, "stop clears running");
            Check(
                dispatch.SelectedVendor == VendorBackend.Xreal,
                "stop keeps the selection"
            );

            RelayDecision restart = dispatch.Decide("start", null);
            Check(
                restart.Target == VendorBackend.Xreal,
                "restart without vendor reuses xreal"
            );
        }

        private static void DisposeClearsSelection()
        {
            var dispatch = new VendorRelayDispatch();
            Start(dispatch, "viture");

            RelayDecision dispose = dispatch.Decide("dispose", null);
            Check(
                dispose.Kind == RelayCommandKind.Dispose &&
                dispose.Target == VendorBackend.Viture,
                "dispose targets the running vendor"
            );
            dispatch.Accepted(dispose);
            Check(!dispatch.IsRunning, "dispose stops");
            Check(
                dispatch.SelectedVendor == VendorBackend.None,
                "dispose clears the selection"
            );
            Check(
                dispatch.Decide("start", null).IsRejected,
                "start after dispose needs a vendor"
            );
        }

        private static void RecenterRequiresARunningVendor()
        {
            var dispatch = new VendorRelayDispatch();
            Check(
                dispatch.Decide("recenter", null).ErrorCode == "unavailable",
                "recenter before start is unavailable"
            );

            Start(dispatch, "viture");
            RelayDecision recenter = dispatch.Decide("recenter", null);
            Check(
                recenter.Kind == RelayCommandKind.Recenter &&
                recenter.Target == VendorBackend.Viture,
                "recenter targets viture"
            );
            RelayDecision recenterWithVendor = dispatch.Decide("recenter", "xreal");
            Check(
                recenterWithVendor.Kind == RelayCommandKind.Recenter &&
                recenterWithVendor.Target == VendorBackend.Viture,
                "recenter stays on the running vendor"
            );
        }

        private static void UnknownCommandAndVendorAreRejected()
        {
            var dispatch = new VendorRelayDispatch();
            Check(
                dispatch.Decide("explode", "viture").ErrorCode == "protocol",
                "unknown command is protocol"
            );
            Check(
                dispatch.Decide("", "viture").ErrorCode == "protocol",
                "empty command is rejected"
            );
            Check(
                dispatch.Decide("configure", "rokid").ErrorCode == "unsupported",
                "unknown vendor is unsupported"
            );
            Check(
                dispatch.Decide("start", "rokid").ErrorCode == "unsupported",
                "start with unknown vendor is unsupported"
            );
            Check(
                dispatch.SelectedVendor == VendorBackend.None,
                "rejections do not change state"
            );
        }

        private static void StartFailureKeepsSelectionButNotRunning()
        {
            var dispatch = new VendorRelayDispatch();
            RelayDecision start = dispatch.Decide("start", "xreal");
            dispatch.StartFailed(start);

            Check(!dispatch.IsRunning, "failed start is not running");
            Check(
                dispatch.SelectedVendor == VendorBackend.Xreal,
                "failed start keeps xreal selected for retry"
            );
            Check(
                dispatch.Decide("start", null).Target == VendorBackend.Xreal,
                "retry without vendor targets xreal"
            );
        }

        private static void StereoModeNamesMatchTheUnityEnum()
        {
            Check(StereoMode.FromRenderingMode(0) == StereoMode.MultiPass, "mode 0 is multiPass");
            Check(StereoMode.FromRenderingMode(1) == StereoMode.SinglePass, "mode 1 is singlePass");
            Check(
                StereoMode.FromRenderingMode(2) == StereoMode.SinglePassInstanced,
                "mode 2 is singlePassInstanced"
            );
            Check(StereoMode.FromRenderingMode(9) == StereoMode.Unknown, "unknown mode value");
            Check(StereoMode.IsStereo(StereoMode.SinglePassInstanced), "singlePassInstanced is stereo");
            Check(StereoMode.IsStereo(StereoMode.MultiPass), "multiPass is stereo");
            Check(!StereoMode.IsStereo(StereoMode.Mono), "mono is not stereo");
            Check(!StereoMode.IsStereo(StereoMode.Unknown), "unknown is not stereo");

            Check(
                StereoDiagnostics.Format(StereoStage.LoaderStarted, StereoMode.SinglePassInstanced, true) ==
                "stage=loaderStarted stereo=singlePassInstanced playerHosted=true",
                "stage diagnostic line"
            );
            Check(
                StereoDiagnostics.Format(null, null, false) ==
                "stage=unknown stereo=unknown playerHosted=false",
                "stage diagnostic falls back honestly"
            );
        }

        private static void Start(VendorRelayDispatch dispatch, string vendor)
        {
            RelayDecision decision = dispatch.Decide("start", vendor);
            Check(
                decision.Kind == RelayCommandKind.Start && !decision.IsRejected,
                $"start {vendor} is accepted"
            );
            dispatch.Accepted(decision);
            Check(
                dispatch.IsRunning && dispatch.RunningVendor == decision.Target,
                $"start {vendor} is running"
            );
        }

        private static void Check(bool condition, string name)
        {
            _checks++;
            if (condition) return;
            _failures++;
            Console.Error.WriteLine("FAIL: " + name);
        }
    }
}
