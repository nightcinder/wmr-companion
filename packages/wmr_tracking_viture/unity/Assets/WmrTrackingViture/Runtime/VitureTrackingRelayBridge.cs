// Minimal Unity-as-a-Library (UaaL) relay bridge for VITURE Pro Neckband +
// Luma Ultra hand and head tracking.
//
// Attach this component to a GameObject named "WmrTrackingRelay" in a minimal
// tracking-only scene (no general Unity UI). Kotlin sends JSON commands via:
//   UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)
// and this script pushes OpenXR-space TrackingFrame JSON strings back through
//   com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin.onUnityFrame(json)
//
// SDK gate: requires Unity 6000.0+, com.unity.xr.hands, and VITURE XR SDK for
// Unity v0.7.0 (com.viture.xr) on the VITURE Pro Neckband.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using UnityEngine;
#if WMR_UNITY_XR_HANDS
using UnityEngine.SubsystemsImplementation;
using UnityEngine.XR.Hands;
#endif
#if WMR_VITURE_XR_SDK
using VitureXR;
#endif

namespace OnyxLens.WmrTrackingViture
{
    public sealed class VitureTrackingRelayBridge : MonoBehaviour
    {
        private const string KotlinPluginClass =
            "com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin";

        private bool _running;
        private Transform _headTransform;

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass _pluginClass;
#endif

#if WMR_UNITY_XR_HANDS
        private XRHandSubsystem _handSubsystem;

        private static readonly (XRHandJointID id, string openXrName)[] JointTable =
        {
            (XRHandJointID.Wrist, "wrist"),
            (XRHandJointID.Palm, "palm"),
            (XRHandJointID.ThumbMetacarpal, "thumbMetacarpal"),
            (XRHandJointID.ThumbProximal, "thumbProximal"),
            (XRHandJointID.ThumbDistal, "thumbDistal"),
            (XRHandJointID.ThumbTip, "thumbTip"),
            (XRHandJointID.IndexMetacarpal, "indexMetacarpal"),
            (XRHandJointID.IndexProximal, "indexProximal"),
            (XRHandJointID.IndexIntermediate, "indexIntermediate"),
            (XRHandJointID.IndexDistal, "indexDistal"),
            (XRHandJointID.IndexTip, "indexTip"),
            (XRHandJointID.MiddleMetacarpal, "middleMetacarpal"),
            (XRHandJointID.MiddleProximal, "middleProximal"),
            (XRHandJointID.MiddleIntermediate, "middleIntermediate"),
            (XRHandJointID.MiddleDistal, "middleDistal"),
            (XRHandJointID.MiddleTip, "middleTip"),
            (XRHandJointID.RingMetacarpal, "ringMetacarpal"),
            (XRHandJointID.RingProximal, "ringProximal"),
            (XRHandJointID.RingIntermediate, "ringIntermediate"),
            (XRHandJointID.RingDistal, "ringDistal"),
            (XRHandJointID.RingTip, "ringTip"),
            (XRHandJointID.LittleMetacarpal, "littleMetacarpal"),
            (XRHandJointID.LittleProximal, "littleProximal"),
            (XRHandJointID.LittleIntermediate, "littleIntermediate"),
            (XRHandJointID.LittleDistal, "littleDistal"),
            (XRHandJointID.LittleTip, "littleTip"),
        };
#endif

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
            if (Camera.main != null)
            {
                _headTransform = Camera.main.transform;
            }
            ReportGlassesModel();
        }

        /// <summary>
        /// Entry point invoked by Kotlin via
        /// UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json).
        /// </summary>
        public void OnCommand(string json)
        {
            if (string.IsNullOrEmpty(json))
            {
                ReportError("protocol", "Empty relay command payload");
                return;
            }

            CommandEnvelope envelope;
            try
            {
                envelope = JsonUtility.FromJson<CommandEnvelope>(json);
            }
            catch (Exception ex)
            {
                ReportError("protocol", "Invalid relay command JSON: " + ex.Message);
                return;
            }

            if (envelope == null || envelope.v != 1 || string.IsNullOrEmpty(envelope.cmd))
            {
                ReportError("protocol", "Unsupported relay command envelope");
                return;
            }

            switch (envelope.cmd)
            {
                case "start":
                    ApplyOptions(envelope.options);
                    StartTracking();
                    break;
                case "configure":
                    ApplyOptions(envelope.options);
                    break;
                case "recenter":
                    Recenter();
                    break;
                case "stop":
                    StopTracking();
                    break;
                case "dispose":
                    StopTracking();
                    break;
                default:
                    ReportError("protocol", "Unknown relay command: " + envelope.cmd);
                    break;
            }
        }

        private void StartTracking()
        {
            ReportGlassesModel();
#if WMR_VITURE_XR_SDK
            var model = Glasses.GetGlassesModel().ToString();
            if (!string.Equals(model, "LumaUltra", StringComparison.OrdinalIgnoreCase))
            {
                ReportError(
                    "unsupported",
                    "VITURE hand tracking requires LumaUltra on Pro Neckband (found " + model + ")"
                );
                return;
            }
            HandTracking.Start();
            if (!HandTracking.IsActive)
            {
                ReportError("unavailable", "VitureXR.HandTracking.Start() did not activate");
                return;
            }
#endif
            _running = true;
        }

        private void StopTracking()
        {
            _running = false;
#if WMR_VITURE_XR_SDK
            if (HandTracking.IsActive)
            {
                HandTracking.Stop();
            }
#endif
        }

        private void ApplyOptions(CommandOptions options)
        {
            if (options == null) return;
#if WMR_VITURE_XR_SDK
            if (!string.IsNullOrEmpty(options.filter_mode))
            {
                HandTracking.filterMode = string.Equals(
                    options.filter_mode,
                    "stable",
                    StringComparison.OrdinalIgnoreCase
                )
                    ? HandTracking.FilterMode.Stable
                    : HandTracking.FilterMode.Responsive;
            }
            if (!string.IsNullOrEmpty(options.aim_sensitivity))
            {
                HandTracking.aimSensitivity = string.Equals(
                    options.aim_sensitivity,
                    "low",
                    StringComparison.OrdinalIgnoreCase
                )
                    ? HandTracking.AimSensitivity.Low
                    : HandTracking.AimSensitivity.High;
            }
#endif
        }

        private void Recenter()
        {
            if (_headTransform == null && Camera.main != null)
            {
                _headTransform = Camera.main.transform;
            }
#if WMR_VITURE_XR_SDK
            try
            {
                HeadTracking.SetWorldOrigin();
            }
            catch (Exception ex)
            {
                ReportError("unavailable", "VitureXR.HeadTracking.SetWorldOrigin() failed: " + ex.Message);
            }
#endif
        }

        private void Update()
        {
            if (!_running) return;
            EmitCurrentFrame();
        }

        /// <summary>
        /// Converts a left-handed Unity pose (p=(x,y,z), q=(qx,qy,qz,qw)) into
        /// right-handed OpenXR space ((x,y,-z), (-qx,-qy,qz,qw)).
        /// </summary>
        public static void UnityToOpenXr(
            Vector3 unityPosition,
            Quaternion unityRotation,
            out Vector3 openXrPosition,
            out Quaternion openXrRotation
        )
        {
            openXrPosition = new Vector3(unityPosition.x, unityPosition.y, -unityPosition.z);
            openXrRotation = new Quaternion(
                -unityRotation.x,
                -unityRotation.y,
                unityRotation.z,
                unityRotation.w
            );
        }

        private void EmitCurrentFrame()
        {
            long timeNs = MonotonicTimeNs();
            var sb = new StringBuilder(2048);
            sb.Append("{\"v\":1,\"space\":\"openxr\",\"time_ns\":")
              .Append(timeNs.ToString(CultureInfo.InvariantCulture));

            if (_headTransform != null)
            {
                UnityToOpenXr(
                    _headTransform.position,
                    _headTransform.rotation,
                    out var headPos,
                    out var headRot
                );
                sb.Append(",\"head\":");
                AppendTrackedPose(sb, headPos, headRot, "high");
            }

#if WMR_UNITY_XR_HANDS
            EnsureHandSubsystem();
            if (_handSubsystem != null && _handSubsystem.running)
            {
                bool hasLeft = _handSubsystem.leftHand.isTracked;
                bool hasRight = _handSubsystem.rightHand.isTracked;
                if (hasLeft || hasRight)
                {
                    sb.Append(",\"hands\":{");
                    if (hasLeft)
                    {
                        sb.Append("\"left\":");
                        AppendHand(sb, _handSubsystem.leftHand, "left");
                    }
                    if (hasLeft && hasRight)
                    {
                        sb.Append(',');
                    }
                    if (hasRight)
                    {
                        sb.Append("\"right\":");
                        AppendHand(sb, _handSubsystem.rightHand, "right");
                    }
                    sb.Append('}');
                }
            }
#endif
            sb.Append('}');
            SendFrameToKotlin(sb.ToString());
        }

#if WMR_UNITY_XR_HANDS
        private readonly List<XRHandSubsystem> _subsystemsCache = new List<XRHandSubsystem>();

        private void EnsureHandSubsystem()
        {
            if (_handSubsystem != null && _handSubsystem.running) return;
            _subsystemsCache.Clear();
            SubsystemManager.GetSubsystems(_subsystemsCache);
            for (int i = 0; i < _subsystemsCache.Count; i++)
            {
                if (_subsystemsCache[i].running)
                {
                    _handSubsystem = _subsystemsCache[i];
                    return;
                }
            }
        }

        private static void AppendHand(StringBuilder sb, XRHand hand, string side)
        {
            sb.Append("{\"hand\":\"").Append(side).Append("\",\"joints\":{");
            bool first = true;
            for (int i = 0; i < JointTable.Length; i++)
            {
                var (id, openXrName) = JointTable[i];
                var joint = hand.GetJoint(id);
                if (!joint.TryGetPose(out Pose unityPose)) continue;
                UnityToOpenXr(
                    unityPose.position,
                    unityPose.rotation,
                    out var pos,
                    out var rot
                );
                if (!first) sb.Append(',');
                first = false;
                sb.Append('"').Append(openXrName).Append("\":");
                AppendTrackedPose(sb, pos, rot, "high");
            }
            sb.Append("}}");
        }
#endif

        private static void AppendTrackedPose(
            StringBuilder sb,
            Vector3 pos,
            Quaternion rot,
            string confidence
        )
        {
            var inv = CultureInfo.InvariantCulture;
            sb.Append("{\"pose\":{\"t\":[")
              .Append(pos.x.ToString("R", inv)).Append(',')
              .Append(pos.y.ToString("R", inv)).Append(',')
              .Append(pos.z.ToString("R", inv))
              .Append("],\"q\":[")
              .Append(rot.x.ToString("R", inv)).Append(',')
              .Append(rot.y.ToString("R", inv)).Append(',')
              .Append(rot.z.ToString("R", inv)).Append(',')
              .Append(rot.w.ToString("R", inv))
              .Append("]},\"confidence\":\"").Append(confidence).Append("\"}");
        }

        private static long MonotonicTimeNs()
        {
            double ticks = Stopwatch.GetTimestamp();
            double ns = (ticks / Stopwatch.Frequency) * 1_000_000_000.0;
            long result = (long)ns;
            return result > 0 ? result : 1L;
        }

        private void ReportGlassesModel()
        {
#if WMR_VITURE_XR_SDK
            string model = Glasses.GetGlassesModel().ToString();
#else
            string model = "LumaUltra";
#endif
#if UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                GetPluginClass()?.CallStatic("onUnityGlassesModel", model);
            }
            catch (Exception)
            {
                // Ignore when running outside the Flutter plugin host.
            }
#endif
        }

        private void SendFrameToKotlin(string frameJson)
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            GetPluginClass()?.CallStatic("onUnityFrame", frameJson);
#endif
        }

        private void ReportError(string code, string message)
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            GetPluginClass()?.CallStatic("onUnityError", code, message);
#endif
        }

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass GetPluginClass()
        {
            if (_pluginClass == null)
            {
                _pluginClass = new AndroidJavaClass(KotlinPluginClass);
            }
            return _pluginClass;
        }
#endif
    }
}
