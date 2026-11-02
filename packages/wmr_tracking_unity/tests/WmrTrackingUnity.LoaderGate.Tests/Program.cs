using System;
using OnyxLens.WmrTrackingUnity.Dispatch;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.XR;
using UnityEngine.XR.Hands;
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
            StartsDisplaylessVitureOnVulkan();
            KeepsDisplaylessSessionWhenHandStartFails();
            StartsDisplaylessVitureOnOpenGles3InUaaL();

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

        private static void StartsDisplaylessVitureOnVulkan()
        {
            GraphicsDeviceType previous = SystemInfo.graphicsDeviceType;
            SystemInfo.graphicsDeviceType = GraphicsDeviceType.Vulkan;
            try
            {
                XRManagerSettings manager = FreshManager();
                var viture = new VitureLoader();
                var hand = new XRHandSubsystem();
                var input = new XRInputSubsystem();
                viture.handSubsystem = hand;
                viture.inputSubsystem = input;
                manager.activeLoaders.Add(viture);
                manager.activeLoaders.Add(new XrealLoader());

                var gate = new VendorLoaderGate(embeddedPlayer: true);
                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitialisedHandOnly,
                    "Vulkan VITURE start uses the displayless path"
                );
                Check(gate.VitureHandOnly, "the gate reports displayless VITURE");
                Check(hand.running && hand.startCalls == 1, "the hand subsystem starts");
                Check(input.running && input.startCalls == 1, "the head subsystem starts");
                Check(
                    manager.startSubsystemsCalls == 0,
                    "the display subsystem is never started on Vulkan"
                );
                Check(manager.activeLoader == viture, "VITURE is the active loader");

                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitialisedHandOnly,
                    "a repeat VITURE start reuses the hand-only session"
                );
                Check(hand.startCalls == 1, "a repeat start does not restart the hand subsystem");
                Check(input.startCalls == 1, "a repeat start does not restart head tracking");

                Check(
                    gate.EnsureOnly(VendorBackend.Xreal) ==
                        VendorLoaderGate.Result.SwitchRequiresRestart,
                    "a vendor switch after displayless VITURE fails typed"
                );
                Check(
                    manager.stopSubsystemsCalls == 0,
                    "a switch never stops the never-started display subsystem"
                );

                gate.Deinitialise();
                Check(!hand.running && hand.stopCalls == 1, "dispose stops hand tracking");
                Check(!input.running && input.stopCalls == 1, "dispose stops head tracking");
                Check(
                    manager.stopSubsystemsCalls == 0 && manager.activeLoader == viture,
                    "dispose keeps the loader so the display is never stopped"
                );

                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitialisedHandOnly,
                    "a start after dispose restarts the hand subsystem"
                );
                Check(hand.running && hand.startCalls == 2, "the hand subsystem restarts");
                Check(input.running && input.startCalls == 2, "head tracking restarts");
            }
            finally
            {
                SystemInfo.graphicsDeviceType = previous;
            }
        }

        private static void KeepsDisplaylessSessionWhenHandStartFails()
        {
            GraphicsDeviceType previous = SystemInfo.graphicsDeviceType;
            SystemInfo.graphicsDeviceType = GraphicsDeviceType.Vulkan;
            try
            {
                XRManagerSettings manager = FreshManager();
                var viture = new VitureLoader();
                var hand = new XRHandSubsystem { failOnStart = true };
                var input = new XRInputSubsystem();
                viture.handSubsystem = hand;
                viture.inputSubsystem = input;
                manager.activeLoaders.Add(viture);

                var gate = new VendorLoaderGate(embeddedPlayer: true);
                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitFailed,
                    "a failed hand-only start reports InitFailed"
                );
                Check(
                    gate.VitureHandOnly,
                    "a failed hand-only start still marks the session displayless"
                );
                Check(
                    manager.startSubsystemsCalls == 0,
                    "a failed hand-only start never starts the display subsystem"
                );

                Check(input.running, "head tracking still starts when hands fail");

                gate.Deinitialise();
                Check(!input.running, "dispose after a failed hand start stops head tracking");
                Check(
                    manager.stopSubsystemsCalls == 0,
                    "dispose after a failed hand-only start never stops the display"
                );
                Check(
                    gate.EnsureOnly(VendorBackend.Xreal) ==
                        VendorLoaderGate.Result.SwitchRequiresRestart,
                    "a vendor switch after a failed hand-only start needs a restart"
                );
                Check(
                    manager.stopSubsystemsCalls == 0,
                    "a vendor switch after a failed hand-only start stops nothing"
                );

                hand.failOnStart = false;
                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitialisedHandOnly,
                    "a later start retries the hand subsystem on the same loader"
                );
                Check(hand.running, "the retried hand subsystem runs");
            }
            finally
            {
                SystemInfo.graphicsDeviceType = previous;
            }
        }

        private static void StartsDisplaylessVitureOnOpenGles3InUaaL()
        {
            GraphicsDeviceType previous = SystemInfo.graphicsDeviceType;
            SystemInfo.graphicsDeviceType = GraphicsDeviceType.OpenGLES3;
            try
            {
                XRManagerSettings manager = FreshManager();
                var viture = new VitureLoader();
                var hand = new XRHandSubsystem();
                var input = new XRInputSubsystem();
                viture.handSubsystem = hand;
                viture.inputSubsystem = input;
                manager.activeLoaders.Add(viture);

                var gate = new VendorLoaderGate(embeddedPlayer: true);
                Check(
                    gate.EnsureOnly(VendorBackend.Viture) ==
                        VendorLoaderGate.Result.InitialisedHandOnly,
                    "the embedded OpenGL ES player still uses the displayless path"
                );
                Check(gate.VitureHandOnly, "the gate reports displayless VITURE on GLES");
                Check(
                    manager.startSubsystemsCalls == 0,
                    "the GLES embedded player never starts the display provider"
                );
                Check(hand.running, "hand tracking runs on GLES");
                Check(input.running, "head tracking runs on GLES");
            }
            finally
            {
                SystemInfo.graphicsDeviceType = previous;
            }
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

        private sealed class VitureLoader : XRLoaderHelper
        {
        }

        private sealed class XrealLoader : XRLoader
        {
        }
    }
}
