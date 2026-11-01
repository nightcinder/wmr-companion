// Minimal stubs for the vendor and XR Hands APIs the bridges compile behind
// WMR_VITURE_XR_SDK, WMR_XREAL_XR_SDK and WMR_UNITY_XR_HANDS. They model only
// the members the bridges call; the point is to type-check the on-device
// branches, not to emulate the SDKs.

using System.Collections.Generic;

namespace UnityEngine
{
    public struct Pose
    {
        public Vector3 position;
        public Quaternion rotation;
    }
}

namespace UnityEngine.SubsystemsImplementation
{
    // Present so `using UnityEngine.SubsystemsImplementation;` resolves; the
    // subsystem query lives in UnityEngine.SubsystemManager below.
}

namespace UnityEngine
{
    public static class SubsystemManager
    {
        public static void GetSubsystems<T>(List<T> store)
        {
        }
    }
}

namespace UnityEngine.XR.Hands
{
    public enum XRHandJointID
    {
        Wrist,
        Palm,
        ThumbMetacarpal,
        ThumbProximal,
        ThumbDistal,
        ThumbTip,
        IndexMetacarpal,
        IndexProximal,
        IndexIntermediate,
        IndexDistal,
        IndexTip,
        MiddleMetacarpal,
        MiddleProximal,
        MiddleIntermediate,
        MiddleDistal,
        MiddleTip,
        RingMetacarpal,
        RingProximal,
        RingIntermediate,
        RingDistal,
        RingTip,
        LittleMetacarpal,
        LittleProximal,
        LittleIntermediate,
        LittleDistal,
        LittleTip,
    }

    public struct XRHandJoint
    {
        public bool TryGetPose(out Pose pose)
        {
            pose = default(Pose);
            return false;
        }
    }

    public struct XRHand
    {
        public bool isTracked { get; set; }

        public XRHandJoint GetJoint(XRHandJointID id) => new XRHandJoint();
    }

    public class XRHandSubsystem
    {
        public bool running { get; set; }

        public XRHand leftHand { get; set; }

        public XRHand rightHand { get; set; }
    }
}

namespace Viture.XR
{
    public enum VitureHandFilterMode
    {
        Responsive = 0,
        Stable = 1,
    }

    public enum VitureHandAimSensitivity
    {
        High = 0,
        Low = 1,
    }

    public static class VitureXR
    {
        public static class Glasses
        {
            public enum Model
            {
                Unknown = 0,
                LumaUltra = 1,
            }

            public static Model GetGlassesModel() => Model.LumaUltra;
        }

        public static class HandTracking
        {
            public static bool IsActive { get; set; }

            public static VitureHandFilterMode filterMode { get; set; }

            public static VitureHandAimSensitivity aimSensitivity { get; set; }

            public static void Start()
            {
            }

            public static void Stop()
            {
            }
        }

        public static class HeadTracking
        {
            public static void SetWorldOrigin()
            {
            }
        }
    }
}

namespace Unity.XR.XREAL
{
    public static class XREALPlugin
    {
        public enum DeviceType
        {
            Unknown = 0,
            XrealAir2Ultra = 1,
        }

        public static DeviceType GetDeviceType() => DeviceType.XrealAir2Ultra;
    }
}
