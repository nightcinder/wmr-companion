#if UNITY_EDITOR
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.XR.Management;
using UnityEngine;
using UnityEngine.XR.Management;
using Unity.XR.XREAL;
using Viture.XR;

namespace OnyxLens.WmrTrackingUnity.Editor
{
    /// <summary>
    /// Configures the Android XR Plug-in Management settings for the unified
    /// export: both vendor loaders assigned and XR initialisation on startup
    /// disabled, so WmrTrackingUnifiedBridge chooses the vendor itself.
    ///
    /// Menu: WMR > Configure unified XR
    /// Batch: Unity -batchmode -quit -projectPath <this folder> -buildTarget Android
    ///        -executeMethod OnyxLens.WmrTrackingUnity.Editor.ConfigureUnifiedXr.Configure
    ///
    /// Requires the VITURE and XREAL Unity packages; the unified project already
    /// needs them to compile its vendor bridges.
    /// </summary>
    public static class ConfigureUnifiedXr
    {
        private const string PerBuildTargetAsset =
            "Assets/XR/XRGeneralSettingsPerBuildTarget.asset";
        private const string SettingsFolder = "Assets/XR/Settings";

        [MenuItem("WMR/Configure unified XR")]
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

            // "Initialize XR on Startup" in XR Plug-in Management.
            general.InitManagerOnStart = false;
            manager.automaticLoading = false;
            manager.automaticRunning = false;

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

            XREALXRLoader xrealLoader = ScriptableObject.CreateInstance<XREALXRLoader>();
            xrealLoader.name = "XREAL Loader";
            AssetDatabase.AddObjectToAsset(xrealLoader, perTarget);

            manager.TrySetLoaders(new List<XRLoader> { vitureLoader, xrealLoader });

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
            vitureSettings.ActivateHandTrackingOnStartup = false;
            EditorUtility.SetDirty(vitureSettings);

            LoadOrCreateSettings<XREALSettings>(
                Path.Combine(SettingsFolder, "XREAL Settings.asset"),
                XREALSettings.k_SettingsKey
            );

            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            Debug.Log(
                "[WMR] Android XR configured: VITURE + XREAL loaders assigned, " +
                "startup initialisation disabled, vendor settings assets present."
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
