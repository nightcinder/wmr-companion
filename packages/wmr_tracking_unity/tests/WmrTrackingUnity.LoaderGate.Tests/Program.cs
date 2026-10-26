using System;
using OnyxLens.WmrTrackingUnity.Dispatch;
using UnityEngine.XR.Management;

namespace OnyxLens.WmrTrackingUnity.LoaderGate.Tests
{
    /// <summary>
    /// Exercises VendorLoaderGate against the minimal XR Management stub. The
    /// regression under test: after the first start, the gate must keep the
    /// other vendor assigned so a later stop-then-start can switch again.
    /// </summary>
    internal static class Program
    {
        private static int _checks;
        private static int _failures;

        private static int Main()
        {
            SwitchesVendorAfterAStartedStop();
            KeepsAlreadyActiveLoader();
            ReportsMissingLoaderAndUnavailableSettings();

            Console.WriteLine(
                _failures == 0
                    ? $"PASS: {_checks} loader-gate checks"
                    : $"FAIL: {_failures} of {_checks} loader-gate checks failed"
            );
            return _failures == 0 ? 0 : 1;
        }

        private static void SwitchesVendorAfterAStartedStop()
        {
            XRManagerSettings manager = FreshManager();
            var viture = new VitureLoader();
            var xreal = new XrealLoader();
            manager.activeLoaders.Add(viture);
            manager.activeLoaders.Add(xreal);

            var gate = new VendorLoaderGate();

            Check(
                gate.EnsureOnly(VendorBackend.Viture) == VendorLoaderGate.Result.Initialised,
                "first start initialises VITURE"
            );
            Check(manager.activeLoader == viture, "VITURE is the active loader");
            Check(
                manager.activeLoaders.Count == 2 && manager.activeLoaders.Contains(xreal),
                "XREAL stays assigned after the first selection"
            );

            gate.Deinitialise();
            Check(manager.activeLoader == null, "deinitialise clears the active loader");

            Check(
                gate.EnsureOnly(VendorBackend.Xreal) == VendorLoaderGate.Result.Initialised,
                "start XREAL after stop succeeds"
            );
            Check(manager.activeLoader == xreal, "XREAL is the active loader");
            Check(
                manager.activeLoaders.Count == 2 && manager.activeLoaders[0] == xreal,
                "XREAL is ordered first and VITURE is retained"
            );

            gate.Deinitialise();
            Check(
                gate.EnsureOnly(VendorBackend.Viture) == VendorLoaderGate.Result.Initialised,
                "switch back to VITURE still succeeds"
            );
            Check(manager.activeLoader == viture, "VITURE is active again");
        }

        private static void KeepsAlreadyActiveLoader()
        {
            XRManagerSettings manager = FreshManager();
            var viture = new VitureLoader();
            manager.activeLoaders.Add(viture);

            var gate = new VendorLoaderGate();
            Check(
                gate.EnsureOnly(VendorBackend.Viture) == VendorLoaderGate.Result.Initialised,
                "single-loader start initialises"
            );
            Check(
                gate.EnsureOnly(VendorBackend.Viture) == VendorLoaderGate.Result.AlreadyActive,
                "repeat start is already active"
            );
            Check(manager.activeLoaders.Count == 1, "already-active keeps the assignment");
        }

        private static void ReportsMissingLoaderAndUnavailableSettings()
        {
            XRManagerSettings manager = FreshManager();
            manager.activeLoaders.Add(new VitureLoader());

            var gate = new VendorLoaderGate();
            Check(
                gate.EnsureOnly(VendorBackend.Xreal) == VendorLoaderGate.Result.MissingLoader,
                "unassigned vendor reports MissingLoader"
            );

            XRGeneralSettings.Instance = null;
            Check(
                gate.EnsureOnly(VendorBackend.Viture) == VendorLoaderGate.Result.Unavailable,
                "missing XR settings reports Unavailable"
            );
        }

        private static XRManagerSettings FreshManager()
        {
            var settings = new XRGeneralSettings();
            XRGeneralSettings.Instance = settings;
            return settings.Manager;
        }

        private static void Check(bool condition, string description)
        {
            _checks++;
            if (condition) return;
            _failures++;
            Console.WriteLine("FAIL: " + description);
        }

        private sealed class VitureLoader : XRLoader
        {
        }

        private sealed class XrealLoader : XRLoader
        {
        }
    }
}
