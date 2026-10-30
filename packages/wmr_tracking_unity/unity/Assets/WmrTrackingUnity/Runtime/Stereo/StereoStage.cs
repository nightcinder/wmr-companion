// Stage and stereo-mode names the hosted scene reports to Kotlin through
// WmrTrackingViturePlugin.onUnityStage(stage, stereoMode).
//
// Plain C# on purpose: the dispatch test project compiles and asserts this
// without Unity or the proprietary SDKs.

using System;

namespace OnyxLens.WmrTrackingUnity.Stereo
{
    public static class StereoStage
    {
        /// <summary>The player was created, attached full-screen and is drawing.</summary>
        public const string PlayerHosted = "playerHosted";

        /// <summary>An XR loader is active; the stereo mode is known from here.</summary>
        public const string LoaderStarted = "loaderStarted";

        /// <summary>The first rendered frame was produced.</summary>
        public const string FirstFrame = "firstFrame";
    }

    public static class StereoMode
    {
        public const string Unknown = "unknown";
        public const string Mono = "mono";
        public const string MultiPass = "multiPass";
        public const string SinglePass = "singlePass";
        public const string SinglePassInstanced = "singlePassInstanced";

        /// <summary>
        /// Maps Unity's <c>XRSettings.StereoRenderingMode</c> enum value
        /// (MultiPass = 0, SinglePass = 1, SinglePassInstanced = 2) to the wire
        /// name. An unknown value is not reported as stereo.
        /// </summary>
        public static string FromRenderingMode(int mode)
        {
            switch (mode)
            {
                case 0:
                    return MultiPass;
                case 1:
                    return SinglePass;
                case 2:
                    return SinglePassInstanced;
                default:
                    return Unknown;
            }
        }

        public static bool IsStereo(string mode) =>
            mode == MultiPass || mode == SinglePass || mode == SinglePassInstanced;
    }

    public static class StereoDiagnostics
    {
        /// <summary>
        /// One line a tester (or the Flutter error) can read: which stage was
        /// reached, in which stereo mode, and whether a player was hosted.
        /// </summary>
        public static string Format(string stage, string stereoMode, bool playerHosted) =>
            "stage=" + (string.IsNullOrEmpty(stage) ? "unknown" : stage) +
            " stereo=" + (string.IsNullOrEmpty(stereoMode) ? StereoMode.Unknown : stereoMode) +
            " playerHosted=" + (playerHosted ? "true" : "false");
    }
}
