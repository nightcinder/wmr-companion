// Exports the XREAL smoke scene as an Android Gradle project containing the
// unityLibrary module that the Flutter host embeds.
//
// Menu: WMR > Export XREAL unityLibrary
// Batch: Unity -batchmode -quit -projectPath <this folder> -buildTarget Android
//        -executeMethod
//        OnyxLens.WmrTrackingXreal.Editor.WmrTrackingXrealExport.Export
//
// The proprietary XREAL SDK is not vendored. The export fails closed with
// install instructions until com.xreal.xr (>= 3.0.0) and com.unity.xr.hands
// are present; those packages supply WMR_XREAL_XR_SDK and WMR_UNITY_XR_HANDS.

#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace OnyxLens.WmrTrackingXreal.Editor
{
    public static class WmrTrackingXrealExport
    {
        public const string ScenePath = "Assets/Scenes/WmrTrackingSmoke.unity";
        public const string ExportDirectory = "Build/Android";
        public const string UnityLibraryPath = "Build/Android/unityLibrary";

        [MenuItem("WMR/Export XREAL unityLibrary")]
        private static void ExportFromMenu()
        {
            Export();
        }

        /// <summary>
        /// Exports the smoke scene as an Android Gradle project and verifies
        /// that the <c>unityLibrary</c> module was produced.
        /// </summary>
        public static void Export()
        {
            RequireSdk();
            if (!File.Exists(ScenePath))
            {
                throw new BuildFailedException(
                    "Smoke scene is missing: " + ScenePath
                );
            }

            ConfigurePlayer();
            EditorUserBuildSettings.buildAppBundle = false;
            EditorUserBuildSettings.exportAsGoogleAndroidProject = true;

            var options = new BuildPlayerOptions
            {
                scenes = new[] { ScenePath },
                locationPathName = ExportDirectory,
                target = BuildTarget.Android,
                options = BuildOptions.None,
            };

            BuildReport report = BuildPipeline.BuildPlayer(options);
            if (report.summary.result != BuildResult.Succeeded)
            {
                throw new BuildFailedException(
                    "XREAL unityLibrary export failed: " + report.summary.result +
                    " (" + report.summary.totalErrors + " error(s))"
                );
            }
            if (!Directory.Exists(UnityLibraryPath))
            {
                throw new BuildFailedException(
                    "Export succeeded but " + UnityLibraryPath +
                    " is missing; check that Export Project is enabled"
                );
            }

            Debug.Log(
                "[WMR] Exported XREAL unityLibrary: " +
                Path.GetFullPath(UnityLibraryPath)
            );
        }

        private static void ConfigurePlayer()
        {
            PlayerSettings.companyName = "OnyxLens";
            PlayerSettings.productName = "WMR Tracking XREAL Smoke";
            PlayerSettings.SetApplicationIdentifier(
                NamedBuildTarget.Android,
                "com.onyxlens.wmr.tracking.smoke.xreal"
            );
            PlayerSettings.SetScriptingBackend(
                NamedBuildTarget.Android,
                ScriptingImplementation.IL2CPP
            );
            PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
            PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel24;
        }

        private static void RequireSdk()
        {
#if !WMR_UNITY_XR_HANDS
            throw new BuildFailedException(
                "com.unity.xr.hands is not installed. Add it from Package Manager " +
                "(Window > Package Manager > Unity Registry > XR Hands), then reopen " +
                "the project and retry the export."
            );
#endif
#if !WMR_XREAL_XR_SDK
            throw new BuildFailedException(
                "The XREAL SDK is not installed. Import com.xreal.xr 3.x from the " +
                "XREAL developer package (tarball or git URL) into this project, " +
                "then reopen it and retry the export. The SDK is not vendored in " +
                "this repository."
            );
#endif
        }
    }
}
#endif
