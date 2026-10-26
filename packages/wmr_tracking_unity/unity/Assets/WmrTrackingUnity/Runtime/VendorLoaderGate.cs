// Selects one vendor XR loader through Unity XR Plug-in Management.
//
// XR Management can initialise only one loader per process (`activeLoader` is
// singular), so a unified app must choose before initialisation. This gate
// reorders the assigned loaders to the selected vendor and initialises it,
// which requires "Initialize XR on Startup" to be off in Player settings.
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
            var loaders = manager.activeLoaders;
            if (loaders != null)
            {
                for (int i = 0; i < loaders.Count; i++)
                {
                    if (Matches(loaders[i], vendor))
                    {
                        selected = loaders[i];
                        break;
                    }
                }
            }
            if (selected == null)
            {
                return Result.MissingLoader;
            }

            if (!manager.TrySetLoaders(new List<XRLoader> { selected }))
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
