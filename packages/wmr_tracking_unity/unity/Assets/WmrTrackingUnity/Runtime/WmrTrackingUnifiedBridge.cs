// Single dispatching Unity-as-a-Library relay for VITURE and XREAL.
//
// The GameObject is still named "WmrTrackingRelay" and the Kotlin entry point
// is unchanged:
//   UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)
//
// `configure` and `start` accept `"vendor":"viture"` or `"vendor":"xreal"`.
// Only the selected vendor bridge is enabled, and only its XR loader is
// initialised. Frame and error payloads keep the per-vendor JSON contract:
// they are emitted by the vendor bridge itself through
// `WmrTrackingViturePlugin` / `WmrTrackingXrealPlugin`.
//
// The scene must carry the two vendor bridges on separate, initially inactive
// child GameObjects so neither vendor's Awake runs before selection. The
// loader gate is best effort: Unity initialises an XR loader per process, so
// this bridge only works when XR Plug-in Management has "Initialize XR on
// Startup" disabled (or when the first loader happens to match the selection).
// See packages/wmr_tracking_unity/README.md for the unproven parts.

using System;
using System.Collections.Generic;
using OnyxLens.WmrTrackingUnity.Dispatch;
using OnyxLens.WmrTrackingViture;
using OnyxLens.WmrTrackingXreal;
using UnityEngine;

namespace OnyxLens.WmrTrackingUnity
{
    public sealed class WmrTrackingUnifiedBridge : MonoBehaviour
    {
        private const string ViturePluginClass =
            "com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin";
        private const string XrealPluginClass =
            "com.onyxlens.wmr_tracking_xreal.WmrTrackingXrealPlugin";

        [SerializeField] private VitureTrackingRelayBridge vitureBackend;
        [SerializeField] private XrealTrackingRelayBridge xrealBackend;

        // Player builds fail closed when the selected loader cannot be
        // initialised; the editor continues so the smoke scene still runs
        // without XR Plug-in Management settings.
        [SerializeField] private bool initialiseVendorLoader = true;

        private readonly VendorRelayDispatch _dispatch = new VendorRelayDispatch();
        private VendorBackend _activeBackend = VendorBackend.None;
        private VendorLoaderGate _loaderGate;

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass _viturePlugin;
        private AndroidJavaClass _xrealPlugin;
#endif

        /// <summary>True while a `start` command selected a running vendor.</summary>
        public bool IsRunning => _dispatch.IsRunning;

        /// <summary>Vendor currently receiving relay commands.</summary>
        public VendorBackend ActiveVendor => _dispatch.RunningVendor;

        /// <summary>Vendor selected by `configure`, even before `start`.</summary>
        public VendorBackend SelectedVendor => _dispatch.SelectedVendor;

        /// <summary>
        /// Raised on the Unity main thread with the exact vendor frame JSON.
        /// The smoke scene subscribes to log frames; production hosts may
        /// ignore it.
        /// </summary>
        public event Action<string> FrameEmitted;

        /// <summary>Raised with (`code`, `message`) for relay-level failures.</summary>
        public event Action<string, string> ErrorReported;

        [Serializable]
        private sealed class CommandEnvelope
        {
            public int v;
            public string cmd;
            public string vendor;
            public CommandOptions options;
        }

        [Serializable]
        private sealed class CommandOptions
        {
            public string filter_mode;
            public string aim_sensitivity;
        }

        private void Awake()
        {
            DontDestroyOnLoad(gameObject);

            if (vitureBackend == null)
            {
                vitureBackend = FindBackend<VitureTrackingRelayBridge>();
            }
            if (xrealBackend == null)
            {
                xrealBackend = FindBackend<XrealTrackingRelayBridge>();
            }
            if (vitureBackend == null || xrealBackend == null)
            {
                Debug.LogError(
                    "[WmrTrackingUnity] both VitureTrackingRelayBridge and " +
                    "XrealTrackingRelayBridge must be present as children"
                );
                enabled = false;
                return;
            }

            vitureBackend.FrameEmitted += OnVitureFrame;
            xrealBackend.FrameEmitted += OnXrealFrame;
            vitureBackend.ErrorReported += OnVendorError;
            xrealBackend.ErrorReported += OnVendorError;

            _loaderGate = new VendorLoaderGate();
            SetBackendEnabled(VendorBackend.Viture, false);
            SetBackendEnabled(VendorBackend.Xreal, false);
        }

        private void OnDestroy()
        {
            if (vitureBackend != null)
            {
                vitureBackend.FrameEmitted -= OnVitureFrame;
                vitureBackend.ErrorReported -= OnVendorError;
            }
            if (xrealBackend != null)
            {
                xrealBackend.FrameEmitted -= OnXrealFrame;
                xrealBackend.ErrorReported -= OnVendorError;
            }
        }

        /// <summary>
        /// Entry point invoked by Kotlin via
        /// UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json).
        /// </summary>
        public void OnCommand(string json)
        {
            if (string.IsNullOrEmpty(json))
            {
                ReportError(VendorBackend.None, "protocol", "Empty relay command payload");
                return;
            }

            CommandEnvelope envelope;
            try
            {
                envelope = JsonUtility.FromJson<CommandEnvelope>(json);
            }
            catch (Exception ex)
            {
                ReportError(
                    VendorBackend.None,
                    "protocol",
                    "Invalid relay command JSON: " + ex.Message
                );
                return;
            }

            if (envelope == null || envelope.v != 1 || string.IsNullOrEmpty(envelope.cmd))
            {
                ReportError(
                    VendorBackend.None,
                    "protocol",
                    "Unsupported relay command envelope"
                );
                return;
            }

            RelayDecision decision = _dispatch.Decide(envelope.cmd, envelope.vendor);
            if (decision.IsRejected)
            {
                ReportError(
                    decision.Target == VendorBackend.None
                        ? _dispatch.SelectedVendor
                        : decision.Target,
                    decision.ErrorCode,
                    decision.ErrorMessage
                );
                return;
            }

            switch (decision.Kind)
            {
                case RelayCommandKind.Configure:
                    HandleConfigure(decision, json);
                    break;
                case RelayCommandKind.Start:
                    HandleStart(decision, json);
                    break;
                case RelayCommandKind.Stop:
                    HandleStop(decision, json);
                    break;
                case RelayCommandKind.Recenter:
                    Forward(decision.Target, json);
                    break;
                case RelayCommandKind.Dispose:
                    HandleDispose(decision, json);
                    break;
            }
        }

        private void HandleConfigure(RelayDecision decision, string json)
        {
            if (!Activate(decision.Target, out string failure))
            {
                ReportError(decision.Target, "unavailable", failure);
                return;
            }
            Forward(decision.Target, json);
            _dispatch.Accepted(decision);
            Debug.Log(
                "[WmrTrackingUnity] configured vendor=" +
                VendorNames.ToWireName(decision.Target)
            );
        }

        private void HandleStart(RelayDecision decision, string json)
        {
            if (!Activate(decision.Target, out string failure))
            {
                _dispatch.StartFailed(decision);
                ReportError(decision.Target, "unavailable", failure);
                return;
            }

            if (initialiseVendorLoader)
            {
                VendorLoaderGate.Result result = _loaderGate.EnsureOnly(decision.Target);
                if (result != VendorLoaderGate.Result.AlreadyActive &&
                    result != VendorLoaderGate.Result.Initialised)
                {
                    string message = VendorLoaderGate.Describe(decision.Target, result);
#if UNITY_EDITOR
                    Debug.LogWarning(
                        "[WmrTrackingUnity] loader gate: " + message +
                        "; continuing in the editor"
                    );
#else
                    _dispatch.StartFailed(decision);
                    ReportError(decision.Target, "unavailable", message);
                    return;
#endif
                }
            }

            Forward(decision.Target, json);
            if (IsBackendRunning(decision.Target))
            {
                _dispatch.Accepted(decision);
                Debug.Log(
                    "[WmrTrackingUnity] started vendor=" +
                    VendorNames.ToWireName(decision.Target)
                );
            }
            else
            {
                // The vendor bridge already reported the concrete error
                // (unsupported glasses, missing SDK/subsystem).
                _dispatch.StartFailed(decision);
            }
        }

        private void HandleStop(RelayDecision decision, string json)
        {
            if (decision.Target != VendorBackend.None)
            {
                Forward(decision.Target, json);
            }
            _dispatch.Accepted(decision);
            Debug.Log("[WmrTrackingUnity] stopped");
        }

        private void HandleDispose(RelayDecision decision, string json)
        {
            if (decision.Target != VendorBackend.None)
            {
                Forward(decision.Target, json);
            }
            _loaderGate?.Deinitialise();
            _dispatch.Accepted(decision);
            Debug.Log("[WmrTrackingUnity] disposed");
        }

        private bool Activate(VendorBackend vendor, out string failure)
        {
            failure = string.Empty;
            if (vendor == VendorBackend.Viture && vitureBackend != null)
            {
                if (_activeBackend != vendor)
                {
                    SetBackendEnabled(_activeBackend, false);
                    SetBackendEnabled(vendor, true);
                    _activeBackend = vendor;
                }
                return true;
            }
            if (vendor == VendorBackend.Xreal && xrealBackend != null)
            {
                if (_activeBackend != vendor)
                {
                    SetBackendEnabled(_activeBackend, false);
                    SetBackendEnabled(vendor, true);
                    _activeBackend = vendor;
                }
                return true;
            }
            failure = "No " + VendorNames.ToWireName(vendor) + " backend is wired";
            return false;
        }

        private void SetBackendEnabled(VendorBackend vendor, bool enabled)
        {
            if (vendor == VendorBackend.Viture && vitureBackend != null)
            {
                SetEnabled(vitureBackend.gameObject, vitureBackend, enabled);
            }
            else if (vendor == VendorBackend.Xreal && xrealBackend != null)
            {
                SetEnabled(xrealBackend.gameObject, xrealBackend, enabled);
            }
        }

        private void SetEnabled(GameObject target, MonoBehaviour behaviour, bool enabled)
        {
            // Separate child objects are required so toggling one vendor does
            // not disable this relay. If a host puts a vendor bridge on the
            // relay object itself, only the component is toggled.
            if (target != gameObject)
            {
                target.SetActive(enabled);
            }
            behaviour.enabled = enabled;
        }

        private bool IsBackendRunning(VendorBackend vendor)
        {
            switch (vendor)
            {
                case VendorBackend.Viture:
                    return vitureBackend != null && vitureBackend.IsRunning;
                case VendorBackend.Xreal:
                    return xrealBackend != null && xrealBackend.IsRunning;
                default:
                    return false;
            }
        }

        private void Forward(VendorBackend vendor, string json)
        {
            if (vendor == VendorBackend.Viture && vitureBackend != null)
            {
                vitureBackend.OnCommand(json);
            }
            else if (vendor == VendorBackend.Xreal && xrealBackend != null)
            {
                xrealBackend.OnCommand(json);
            }
        }

        private void OnVitureFrame(string frameJson)
        {
            if (_activeBackend == VendorBackend.Viture)
            {
                FrameEmitted?.Invoke(frameJson);
            }
        }

        private void OnXrealFrame(string frameJson)
        {
            if (_activeBackend == VendorBackend.Xreal)
            {
                FrameEmitted?.Invoke(frameJson);
            }
        }

        private void OnVendorError(string code, string message)
        {
            ErrorReported?.Invoke(code, message);
        }

        private void ReportError(VendorBackend vendor, string code, string message)
        {
            Debug.LogError(
                "[WmrTrackingUnity] relay error vendor=" +
                VendorNames.ToWireName(vendor) +
                " code=" + code + " message=" + message
            );
            ErrorReported?.Invoke(code, message);
#if UNITY_ANDROID && !UNITY_EDITOR
            AndroidJavaClass plugin = GetPluginClass(vendor);
            try
            {
                plugin?.CallStatic("onUnityError", code, message);
            }
            catch (Exception)
            {
                // Ignore when running outside the Flutter plugin host.
            }
#endif
        }

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass GetPluginClass(VendorBackend vendor)
        {
            if (vendor == VendorBackend.Viture)
            {
                if (_viturePlugin == null)
                {
                    _viturePlugin = new AndroidJavaClass(ViturePluginClass);
                }
                return _viturePlugin;
            }
            if (vendor == VendorBackend.Xreal)
            {
                if (_xrealPlugin == null)
                {
                    _xrealPlugin = new AndroidJavaClass(XrealPluginClass);
                }
                return _xrealPlugin;
            }
            return null;
        }
#endif

        private T FindBackend<T>() where T : MonoBehaviour
        {
            T[] found = GetComponentsInChildren<T>(true);
            return found.Length > 0 ? found[0] : null;
        }
    }
}
