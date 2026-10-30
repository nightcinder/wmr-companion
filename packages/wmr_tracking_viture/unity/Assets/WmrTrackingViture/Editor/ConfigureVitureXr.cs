// Configures Android XR Plug-in Management for the per-vendor VITURE export.
//
// VITURE hand tracking only produces frames while the VITURE XR loader renders
// the scene in stereo 3D (SpaceWalker mode). A mono 2D Unity player has no
// hands and `VitureXR.HandTracking.Start()` can stall the launch instead of
// failing, so the loader is assigned and initialised on startup here.
//
// Menu: WMR > Configure VITURE XR
// Batch: Unity -batchmode -quit -projectPath <this folder> -buildTarget Android
//        -executeMethod OnyxLens.WmrTrackingViture.Editor.ConfigureVitureXr.Configure
//
// Requires the VITURE XR SDK; the export calls this after RequireSdk().

#if UNITY_EDITOR && WMR_VITURE_XR_SDK
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.XR.Management;
using UnityEngine;
using UnityEngine.XR.Management;
using Viture.XR;

namespace OnyxLens.WmrTrackingViture.Editor
{
    /// <summary>
    /// Assigns the VITURE loader for Android and enables "Initialize XR on
    /// Startup" so the exported <c>unityLibrary</c> is stereoscopic from launch.
    /// Hand tracking is still started by the Android host, not at startup.
    /// </summary>
    public static class ConfigureVitureXr
    {
        private const string PerBuildTargetAsset =
            "Assets/XR/XRGeneralSettingsPerBuildTarget.asset";
        private const string SettingsFolder = "Assets/XR/Settings";

        [MenuItem("WMR/Configure VITURE XR")]
        public static void Configure()
        {
            XRGeneralSettingsPerBuildTarget perTarget =
                AssetDatabase.LoadAssetAtPath<XRGeneralSettingsPerBuildTarget>(
                    PerBuildTargetAsset
                );
            if (perTarget == null)
            {
                Directory.CreateDirectory("Assets/XR");
                perTarget = ScriptableObject.CreateInstance<XRGeneralSettingsPerBuildTarget>();
                AssetDatabase.CreateAsset(perTarget, PerBuildTargetAsset);
                AssetDatabase.SaveAssets();
            }

            if (!perTarget.HasSettingsForBuildTarget(BuildTargetGroup.Android))
            {
                perTarget.CreateDefaultSettingsForBuildTarget(BuildTargetGroup.Android);
            }
            if (!perTarget.HasManagerSettingsForBuildTarget(BuildTargetGroup.Android))
            {
                perTarget.CreateDefaultManagerSettingsForBuildTarget(
                    BuildTargetGroup.Android
                );
            }

            XRGeneralSettings general =
                perTarget.SettingsForBuildTarget(BuildTargetGroup.Android);
            XRManagerSettings manager =
                perTarget.ManagerSettingsForBuildTarget(BuildTargetGroup.Android);

            // Stereo 3D from launch: the VITURE loader owns the display before
            // the host sends `start`.
            general.InitManagerOnStart = true;
            manager.automaticLoading = true;
            manager.automaticRunning = true;

            if (manager.activeLoaders != null)
            {
                foreach (XRLoader loader in manager.activeLoaders)
                {
                    if (loader != null)
                    {
                        Object.DestroyImmediate(loader, true);
                    }
                }
            }

            VitureLoader vitureLoader = ScriptableObject.CreateInstance<VitureLoader>();
            vitureLoader.name = "VITURE Loader";
            AssetDatabase.AddObjectToAsset(vitureLoader, perTarget);
            manager.TrySetLoaders(new List<XRLoader> { vitureLoader });

            EditorUtility.SetDirty(manager);
            EditorUtility.SetDirty(general);
            EditorUtility.SetDirty(perTarget);

            EditorBuildSettings.AddConfigObject(
                XRGeneralSettings.k_SettingsKey,
                perTarget,
                true
            );

            VitureSettings vitureSettings = LoadOrCreateSettings<VitureSettings>(
                Path.Combine(SettingsFolder, "VITURE Settings.asset"),
                VitureConstants.k_SettingsKey
            );
            // `start` stays host-owned (default-off flag, CAMERA permission).
            vitureSettings.ActivateHandTrackingOnStartup = false;
            EditorUtility.SetDirty(vitureSettings);

            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            Debug.Log(
                "[WMR] VITURE Android XR configured: loader assigned, initialize " +
                "on startup enabled, hand tracking activation left to the host."
            );
        }

        private static T LoadOrCreateSettings<T>(string path, string configKey)
            where T : ScriptableObject
        {
            T settings = AssetDatabase.LoadAssetAtPath<T>(path);
            if (settings == null)
            {
                Directory.CreateDirectory(SettingsFolder);
                settings = ScriptableObject.CreateInstance<T>();
                AssetDatabase.CreateAsset(settings, path);
            }

            EditorBuildSettings.AddConfigObject(configKey, settings, true);
            return settings;
        }
    }
}
#endif
