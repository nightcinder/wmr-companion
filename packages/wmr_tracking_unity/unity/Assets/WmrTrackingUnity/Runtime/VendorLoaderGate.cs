// Selects one vendor XR loader through Unity XR Plug-in Management.
//
// XR Management can initialise only one loader per process (`activeLoader` is
// singular), so a unified app must choose before initialisation. This gate
// caches the full assigned loader list, reorders it so the selected vendor is
// first, and initialises it. The other vendor stays assigned so a later
// stop-then-start can switch again; replacing the list with the single
// selected loader would lose it until the project or app restarts. This
// requires "Initialize XR on Startup" to be off in Player settings.
// Whether VITURE and XREAL loaders can be deinitialised and re-initialised
// reliably is unproven; see packages/wmr_tracking_unity/README.md.

using System;
using System.Collections.Generic;
using OnyxLens.WmrTrackingUnity.Dispatch;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.XR;
using UnityEngine.XR.Management;
#if WMR_UNITY_XR_HANDS
using UnityEngine.XR.Hands;
#endif

namespace OnyxLens.WmrTrackingUnity
{
    internal sealed class VendorLoaderGate
    {
        // Full loader assignment captured before the first TrySetLoaders call.
        // XRManagerSettings.activeLoaders is what the host assigned in XR
        // Plug-in Management; retaining the other vendor there is what lets a
        // later switch find it.
        private List<XRLoader> _assignedLoaders;

        // True when this gate is driving the embedded UaaL player. The
        // companion hosts Unity as a library inside MainActivity; the display
        // provider creates its own mXRSurfaceView and takes the Activity
        // surface, which hijacks or crashes the Flutter host. The embedded
        // player therefore starts the input (head) and hand subsystems on
        // their own (ONY-840).
        private readonly bool _embeddedPlayer;

        // Set when VITURE runs without its XR display subsystem.
        private bool _vitureHandOnly;

        public VendorLoaderGate(bool embeddedPlayer = false)
        {
            _embeddedPlayer = embeddedPlayer;
        }

        public enum Result
        {
            Unavailable,
            AlreadyActive,
            Initialised,
            InitialisedHandOnly,
            MissingLoader,
            InitFailed,
            GraphicsApiUnsupported,
            SwitchRequiresRestart,
        }

        /// <summary>
        /// True when VITURE's head and hand subsystems were started without
        /// the display subsystem, so the vendor provider never creates its
        /// own Android surface.
        /// </summary>
        public bool VitureHandOnly => _vitureHandOnly;

        public Result EnsureOnly(VendorBackend vendor)
        {
            XRGeneralSettings settings = XRGeneralSettings.Instance;
            if (settings == null || settings.Manager == null)
            {
                return Result.Unavailable;
            }

            XRManagerSettings manager = settings.Manager;
            manager.automaticLoading = false;
            manager.automaticRunning = false;

            if (_assignedLoaders == null)
            {
                _assignedLoaders = new List<XRLoader>();
                if (manager.activeLoaders != null)
                {
                    _assignedLoaders.AddRange(manager.activeLoaders);
                }
            }

            if (manager.activeLoader == null)
            {
                _vitureHandOnly = false;
            }
            else if (Matches(manager.activeLoader, vendor))
            {
                if (_vitureHandOnly && vendor == VendorBackend.Viture)
                {
#if WMR_UNITY_XR_HANDS
                    // A dispose stops the input and hand subsystems but keeps
                    // the loader so the never-started display is never
                    // stopped; a later start must bring tracking back.
                    return StartVitureHandOnly(manager.activeLoader)
                        ? Result.InitialisedHandOnly
                        : Result.InitFailed;
#else
                    return Result.GraphicsApiUnsupported;
#endif
                }
                return Result.AlreadyActive;
            }
            else if (_vitureHandOnly)
            {
                // Stopping subsystems here would call VitureLoader.Stop(),
                // which stops the never-started VITURE display subsystem. The
                // vendor SDK null-derefs on that path (ONY-802), so a vendor
                // switch after a displayless VITURE session needs a restart.
                return Result.SwitchRequiresRestart;
            }
            else
            {
                manager.StopSubsystems();
                manager.DeinitializeLoader();
            }

            XRLoader selected = null;
            for (int i = 0; i < _assignedLoaders.Count; i++)
            {
                if (Matches(_assignedLoaders[i], vendor))
                {
                    selected = _assignedLoaders[i];
                    break;
                }
            }
            if (selected == null)
            {
                return Result.MissingLoader;
            }

            // Selected loader first so XR Management initialises it, but keep
            // the other vendor assigned for the next stop-then-start switch.
            var ordered = new List<XRLoader>(_assignedLoaders.Count);
            ordered.Add(selected);
            for (int i = 0; i < _assignedLoaders.Count; i++)
            {
                if (_assignedLoaders[i] != null && _assignedLoaders[i] != selected)
                {
                    ordered.Add(_assignedLoaders[i]);
                }
            }

            if (!manager.TrySetLoaders(ordered))
            {
                return Result.InitFailed;
            }
            manager.InitializeLoaderSync();
            if (manager.activeLoader == null)
            {
                return Result.InitFailed;
            }

            if (vendor == VendorBackend.Viture && NeedsVitureHandOnly())
            {
#if WMR_UNITY_XR_HANDS
                // Record the displayless session before the start attempt: the
                // display subsystem was never started, so even a failed
                // tracking start must keep StopSubsystems() off the vendor
                // stop path, which null-derefs on a display it never started.
                _vitureHandOnly = true;
                if (!StartVitureHandOnly(manager.activeLoader))
                {
                    return Result.InitFailed;
                }
                return Result.InitialisedHandOnly;
#else
                // No hand subsystem to start instead of the display. Fail
                // closed rather than starting the display on a graphics API
                // the vendor provider cannot use.
                return Result.GraphicsApiUnsupported;
#endif
            }

            manager.StartSubsystems();
            return Result.Initialised;
        }

        public void Deinitialise()
        {
            XRGeneralSettings settings = XRGeneralSettings.Instance;
            if (settings == null || settings.Manager == null) return;
            XRManagerSettings manager = settings.Manager;
            if (manager.activeLoader == null) return;

            if (_vitureHandOnly)
            {
                // A display subsystem that was created but never started must
                // not go through VitureLoader.Stop(): the vendor stop path
                // assumes the gfx thread exists and crashes when it does not.
#if WMR_UNITY_XR_HANDS
                StopVitureHandOnly(manager.activeLoader);
#else
                _vitureHandOnly = false;
#endif
                return;
            }

            manager.StopSubsystems();
            manager.DeinitializeLoader();
        }

        public static string Describe(VendorBackend vendor, Result result)
        {
            string name = VendorNames.ToWireName(vendor);
            switch (result)
            {
                case Result.AlreadyActive:
                    return "The " + name + " XR loader is already active";
                case Result.Initialised:
                    return "Initialised the " + name + " XR loader";
                case Result.InitialisedHandOnly:
                    return "Started " + name + " head and hand tracking without " +
                        "the XR display subsystem (the embedded player must not " +
                        "create the VITURE display surface)";
                case Result.MissingLoader:
                    return "No " + name + " XR loader is assigned in XR Plug-in Management";
                case Result.InitFailed:
                    return "The " + name + " XR loader did not initialise";
                case Result.GraphicsApiUnsupported:
                    return "VITURE hand tracking needs a Unity player built with " +
                        "OpenGL ES 3; this player uses " +
                        SystemInfo.graphicsDeviceType + ", which would crash the " +
                        "VITURE display provider. Rebuild the unityLibrary with " +
                        "OpenGL ES 3.";
                case Result.SwitchRequiresRestart:
                    return "VITURE is running without its XR display subsystem; " +
                        "restart the app before switching to another vendor";
                default:
                    return "XR Plug-in Management settings are unavailable";
            }
        }

        private bool NeedsVitureHandOnly()
        {
#if UNITY_EDITOR
            // The editor's graphics device is not the exported Android one,
            // and the editor smoke scene has no host Activity to hijack.
            return false;
#else
            if (_embeddedPlayer)
            {
                // Starting the display provider in the host Activity creates
                // mXRSurfaceView and takes its surface, which crashes or
                // blanks the Flutter host on every graphics API (ONY-840).
                // Head and hand tracking do not need it.
                return true;
            }
            return SystemInfo.graphicsDeviceType != GraphicsDeviceType.OpenGLES3;
#endif
        }

#if WMR_UNITY_XR_HANDS
        private static bool StartVitureHandOnly(XRLoader loader)
        {
            try
            {
                XRLoaderHelper helper = loader as XRLoaderHelper;
                if (helper == null) return false;
                XRHandSubsystem hand = helper.GetLoadedSubsystem<XRHandSubsystem>();
                if (hand == null) return false;

                // Head pose comes from the loader's input subsystem; without
                // it the player stays in 0DoF even though hands start.
                XRInputSubsystem input = helper.GetLoadedSubsystem<XRInputSubsystem>();
                if (input != null && !input.running)
                {
                    input.Start();
                }
                if (!hand.running)
                {
                    hand.Start();
                }
                return hand.running;
            }
            catch (Exception ex)
            {
                Debug.LogError(
                    "[WmrTrackingUnity] VITURE displayless start failed: " + ex.Message
                );
                return false;
            }
        }

        private static void StopVitureHandOnly(XRLoader loader)
        {
            try
            {
                XRLoaderHelper helper = loader as XRLoaderHelper;
                if (helper == null) return;
                XRHandSubsystem hand = helper.GetLoadedSubsystem<XRHandSubsystem>();
                if (hand != null && hand.running)
                {
                    hand.Stop();
                }
                XRInputSubsystem input = helper.GetLoadedSubsystem<XRInputSubsystem>();
                if (input != null && input.running)
                {
                    input.Stop();
                }
            }
            catch (Exception ex)
            {
                Debug.LogError(
                    "[WmrTrackingUnity] VITURE displayless stop failed: " + ex.Message
                );
            }
        }
#endif

        private static bool Matches(XRLoader loader, VendorBackend vendor)
        {
            if (loader == null) return false;
            string typeName = loader.GetType().FullName ?? string.Empty;
            switch (vendor)
            {
                case VendorBackend.Viture:
                    return typeName.IndexOf("viture", StringComparison.OrdinalIgnoreCase) >= 0;
                case VendorBackend.Xreal:
                    return typeName.IndexOf("xreal", StringComparison.OrdinalIgnoreCase) >= 0;
                default:
                    return false;
            }
        }
    }
}
