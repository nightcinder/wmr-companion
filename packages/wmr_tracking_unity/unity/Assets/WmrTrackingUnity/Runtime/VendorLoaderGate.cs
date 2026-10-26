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
using UnityEngine.XR.Management;

namespace OnyxLens.WmrTrackingUnity
{
    internal sealed class VendorLoaderGate
    {
        // Full loader assignment captured before the first TrySetLoaders call.
        // XRManagerSettings.activeLoaders is what the host assigned in XR
        // Plug-in Management; retaining the other vendor there is what lets a
        // later switch find it.
        private List<XRLoader> _assignedLoaders;

        public enum Result
        {
            Unavailable,
            AlreadyActive,
            Initialised,
            MissingLoader,
            InitFailed,
        }

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

            if (manager.activeLoader != null)
            {
                if (Matches(manager.activeLoader, vendor))
                {
                    return Result.AlreadyActive;
                }
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
            manager.StartSubsystems();
            return Result.Initialised;
        }

        public void Deinitialise()
        {
            XRGeneralSettings settings = XRGeneralSettings.Instance;
            if (settings == null || settings.Manager == null) return;
            XRManagerSettings manager = settings.Manager;
            if (manager.activeLoader == null) return;
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
                case Result.MissingLoader:
                    return "No " + name + " XR loader is assigned in XR Plug-in Management";
                case Result.InitFailed:
                    return "The " + name + " XR loader did not initialise";
                default:
                    return "XR Plug-in Management settings are unavailable";
            }
        }

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
