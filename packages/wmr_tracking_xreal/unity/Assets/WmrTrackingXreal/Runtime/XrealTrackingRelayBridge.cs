// Minimal Unity-as-a-Library (UaaL) relay bridge for the XREAL Air 2 Ultra
// head and hand tracking slice.
//
// Attach this component to a GameObject named "WmrTrackingRelay" in a minimal
// tracking-only scene (no general Unity UI). Kotlin sends JSON commands via:
//   UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)
// and this script pushes OpenXR-space TrackingFrame JSON strings back through
//   com.onyxlens.wmr_tracking_xreal.WmrTrackingXrealPlugin.onUnityFrame(json)
//
// SDK gate: requires Unity 2021.3+ / 6000.0, com.unity.xr.hands, and the XREAL
// SDK for Unity 3.x (com.xreal.xr). The XREAL project must enable XR Plug-in
// Management -> XREAL, set Initial Input Source to Hands, and include
// XREAL_DEVICE_CATEGORY_REALITY in Support Devices.

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
#if WMR_XREAL_XR_SDK
using Unity.XR.XREAL;
#endif

namespace OnyxLens.WmrTrackingXreal
{
    public sealed class XrealTrackingRelayBridge : MonoBehaviour
    {
        private const string KotlinPluginClass =
            "com.onyxlens.wmr_tracking_xreal.WmrTrackingXrealPlugin";

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
                    StartTracking();
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

        private static string NormalizeModel(string value)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            var sb = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (char.IsLetterOrDigit(c)) sb.Append(char.ToLowerInvariant(c));
            }
            return sb.ToString();
        }

        private static string CurrentGlassesModel()
        {
#if WMR_XREAL_XR_SDK
            try
            {
                return XREALPlugin.GetDeviceType().ToString();
            }
            catch (Exception)
            {
                return "Unknown";
            }
#else
            // Without the SDK gate the model is unknown; never fail open.
            return "Unknown";
#endif
        }

        private void StartTracking()
        {
            ReportGlassesModel();
            string model = CurrentGlassesModel();
            if (NormalizeModel(model) != "air2ultra")
            {
                ReportError(
                    "unsupported",
                    "XREAL hand tracking requires Air 2 Ultra (found " + model + ")"
                );
                return;
            }

#if WMR_UNITY_XR_HANDS
            EnsureHandSubsystem();
            if (_handSubsystem == null || !_handSubsystem.running)
            {
                ReportError(
                    "unavailable",
                    "XREAL XR Hands subsystem is not running; set the XREAL input source to Hands"
                );
                return;
            }
#else
            ReportError(
                "unavailable",
                "Unity XR Hands package is not installed in this build"
            );
            return;
#endif
            _running = true;
        }

        private void StopTracking()
        {
            _running = false;
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
            string model = CurrentGlassesModel();
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
