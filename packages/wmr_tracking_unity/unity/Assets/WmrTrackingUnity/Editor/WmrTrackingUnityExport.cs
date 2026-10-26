// Exports the unified smoke scene as one Android Gradle project containing a
// single `unityLibrary` module with both the VITURE and XREAL SDKs installed.
//
// Menu: WMR > Export unified unityLibrary
// Batch: Unity -batchmode -quit -projectPath <this folder> -buildTarget Android
//        -executeMethod
//        OnyxLens.WmrTrackingUnity.Editor.WmrTrackingUnityExport.Export
//
// Neither proprietary SDK is vendored. The export fails closed until
// com.viture.xr (>= 0.9.0), com.xreal.xr (>= 3.0.0) and com.unity.xr.hands are
// present. The post-export check proves that exactly one unityLibrary exists
// and reports same-ABI native library name collisions, which are the most
// likely way two SDKs break a shared export.

#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace OnyxLens.WmrTrackingUnity.Editor
{
    public static class WmrTrackingUnityExport
    {
        public const string ScenePath = "Assets/Scenes/WmrTrackingUnifiedSmoke.unity";
        public const string VitureBridgeAsset =
            "Assets/WmrTrackingViture/Runtime/VitureTrackingRelayBridge.cs";
        public const string XrealBridgeAsset =
            "Assets/WmrTrackingXreal/Runtime/XrealTrackingRelayBridge.cs";
        public const string ExportDirectory = "Build/Android";
        public const string UnityLibraryPath = "Build/Android/unityLibrary";
        public const string NativeLibraryReportPath =
            "Build/Android/unityLibrary-native-libs.txt";

        [MenuItem("WMR/Export unified unityLibrary")]
        private static void ExportFromMenu()
        {
            Export();
        }

        /// <summary>
        /// Exports the unified smoke scene as an Android Gradle project and
        /// verifies the single unityLibrary plus its native library layout.
        /// </summary>
        public static void Export()
        {
            RequireSdks();
            ConfigureUnifiedXr.Configure();
            RequireVendorRuntime();
            if (!File.Exists(ScenePath))
            {
                throw new BuildFailedException(
                    "Unified smoke scene is missing: " + ScenePath
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
                    "Unified unityLibrary export failed: " + report.summary.result +
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

            VerifySingleUnityLibrary();
            Debug.Log(
                "[WMR] Exported unified unityLibrary: " +
                Path.GetFullPath(UnityLibraryPath) +
                " (native library report: " + NativeLibraryReportPath + ")"
            );
        }

        private static void ConfigurePlayer()
        {
            PlayerSettings.companyName = "OnyxLens";
            PlayerSettings.productName = "WMR Tracking Unified Smoke";
            PlayerSettings.SetApplicationIdentifier(
                NamedBuildTarget.Android,
                "com.onyxlens.wmr.tracking.smoke.unified"
            );
            PlayerSettings.SetScriptingBackend(
                NamedBuildTarget.Android,
                ScriptingImplementation.IL2CPP
            );
            PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
            PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel24;
        }

        private static void VerifySingleUnityLibrary()
        {
            string[] libraries = Directory.GetDirectories(
                ExportDirectory,
                "unityLibrary",
                SearchOption.AllDirectories
            );
            if (libraries.Length != 1)
            {
                throw new BuildFailedException(
                    "Expected exactly one unityLibrary, found " +
                    libraries.Length + ": " + string.Join(", ", libraries)
                );
            }
            if (!string.Equals(
                Path.GetFullPath(libraries[0]),
                Path.GetFullPath(UnityLibraryPath),
                StringComparison.Ordinal))
            {
                throw new BuildFailedException(
                    "unityLibrary was exported to " + libraries[0] +
                    " instead of " + UnityLibraryPath
                );
            }

            string[] nativeLibraries = Directory.GetFiles(
                UnityLibraryPath,
                "*.so",
                SearchOption.AllDirectories
            );
            var report = new List<string>();
            var collisions = new List<string>();

            foreach (var group in nativeLibraries
                .GroupBy(
                    file => AbiAndName(file),
                    StringComparer.OrdinalIgnoreCase)
                .OrderBy(group => group.Key, StringComparer.OrdinalIgnoreCase))
            {
                if (group.Count() > 1)
                {
                    collisions.Add(group.Key);
                }
            }
            foreach (string file in nativeLibraries
                .Select(RelativeToLibrary)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                report.Add(file);
            }

            Directory.CreateDirectory(Path.GetDirectoryName(NativeLibraryReportPath));
            File.WriteAllLines(NativeLibraryReportPath, report);

            if (collisions.Count > 0)
            {
                throw new BuildFailedException(
                    "Two native libraries map to the same ABI and file name, so " +
                    "one would overwrite the other: " + string.Join(", ", collisions) +
                    ". See " + NativeLibraryReportPath + "."
                );
            }

            bool hasViture = nativeLibraries.Any(file =>
                Path.GetFileName(file).IndexOf("viture", StringComparison.OrdinalIgnoreCase) >= 0);
            bool hasXreal = nativeLibraries.Any(file =>
                Path.GetFileName(file).IndexOf("xreal", StringComparison.OrdinalIgnoreCase) >= 0 ||
                Path.GetFileName(file).IndexOf("nrsdk", StringComparison.OrdinalIgnoreCase) >= 0);
            if (!hasViture || !hasXreal)
            {
                Debug.LogWarning(
                    "[WMR] Native library names do not contain both vendor names " +
                    "(viture=" + hasViture + ", xreal=" + hasXreal + "). The " +
                    "SDKs may still be linked under different names; check the " +
                    "report and the SDK package contents before shipping."
                );
            }
        }

        private static string AbiAndName(string file)
        {
            string directory = Path.GetFileName(Path.GetDirectoryName(file)) ?? string.Empty;
            return directory + "/" + Path.GetFileName(file);
        }

        private static string RelativeToLibrary(string file)
        {
            string relative = file.StartsWith(UnityLibraryPath, StringComparison.Ordinal)
                ? file.Substring(UnityLibraryPath.Length)
                : file;
            return relative.TrimStart('/', '\\').Replace('\\', '/');
        }

        private static void RequireVendorRuntime()
        {
            string scene = File.ReadAllText(ScenePath);
            RequireVendorScript(
                VitureBridgeAsset,
                "OnyxLens.WmrTrackingViture.VitureTrackingRelayBridge, WmrTrackingViture.Runtime",
                scene
            );
            RequireVendorScript(
                XrealBridgeAsset,
                "OnyxLens.WmrTrackingXreal.XrealTrackingRelayBridge, WmrTrackingXreal.Runtime",
                scene
            );
        }

        // The smoke scene stores the two vendor bridges by script GUID. The
        // unified project owns copies of the vendor Runtime folders (keep them
        // in sync with
        // packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh); this
        // check fails before the build when a copy or its scene reference is
        // missing.
        private static void RequireVendorScript(
            string assetPath,
            string assemblyQualifiedName,
            string scene)
        {
            if (!File.Exists(assetPath))
            {
                throw new BuildFailedException(
                    "Vendor relay bridge is missing from the unified project: " +
                    assetPath + ". Run " +
                    "packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh " +
                    "and reopen the project."
                );
            }

            string guid = AssetDatabase.AssetPathToGUID(assetPath);
            if (string.IsNullOrEmpty(guid) || !scene.Contains("guid: " + guid))
            {
                throw new BuildFailedException(
                    "The unified smoke scene does not reference " + assetPath +
                    " (GUID " + guid + "). Re-import the vendor scripts and " +
                    "resave the scene."
                );
            }

            Type type = Type.GetType(assemblyQualifiedName);
            if (type == null || !typeof(MonoBehaviour).IsAssignableFrom(type))
            {
                throw new BuildFailedException(
                    "Vendor relay assembly is not compiled: " +
                    assemblyQualifiedName + ". Check the vendor Runtime asmdef " +
                    "under the unified project and the SDK package references."
                );
            }
        }

        private static void RequireSdks()
        {
#if !WMR_UNITY_XR_HANDS
            throw new BuildFailedException(
                "com.unity.xr.hands is not installed. Add it from Package Manager " +
                "(Window > Package Manager > Unity Registry > XR Hands), then reopen " +
                "the project and retry the export."
            );
#endif
#if !WMR_VITURE_XR_SDK
            throw new BuildFailedException(
                "The VITURE XR SDK is not installed. Import com.viture.xr v0.9.0 " +
                "from the VITURE developer package into this project, then reopen " +
                "it and retry the export. The SDK is not vendored."
            );
#endif
#if !WMR_XREAL_XR_SDK
            throw new BuildFailedException(
                "The XREAL SDK is not installed. Import com.xreal.xr 3.x from the " +
                "XREAL developer package into this project, then reopen it and " +
                "retry the export. The SDK is not vendored."
            );
#endif
        }
    }
}
#endif
