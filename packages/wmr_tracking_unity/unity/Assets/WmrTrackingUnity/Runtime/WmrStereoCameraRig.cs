// The minimal stereo scene for the VITURE UaaL player (ONY-612).
//
// Attach to the Main Camera of the exported scene. It assumes the camera is
// already the XR/stereo target, keeps it targeting both eyes, builds a small
// depth ladder so a tester can see one coherent 3D image, and reports the
// startup stages to Kotlin through
//   com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin.onUnityStage
//
// The VITURE loader owns the actual stereo presentation mode; this script only
// reads it back. It never switches a mono player into stereo at runtime.

using System;
using System.Collections;
using OnyxLens.WmrTrackingUnity.Stereo;
using UnityEngine;
using UnityEngine.XR;

namespace OnyxLens.WmrTrackingUnity
{
    [DisallowMultipleComponent]
    [RequireComponent(typeof(Camera))]
    public sealed class WmrStereoCameraRig : MonoBehaviour
    {
        private const string ViturePluginClass =
            "com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin";

        [SerializeField] private bool reportToHost = true;

        // A late loader is reported instead of leaving the tester on a blank
        // surface with no explanation.
        [SerializeField, Min(1f)] private float loaderTimeoutSeconds = 10f;

        [SerializeField, Min(1f)] private float firstFrameTimeoutSeconds = 20f;

        private Camera _camera;
        private bool _contentBuilt;
        private bool _loaderReported;
        private bool _firstFrameReported;
        private bool _timeoutReported;
        private bool _sessionBegun;
        private float _awakeAt;
        private string _stereoMode = StereoMode.Unknown;

        /// <summary>Wire name of the last stereo mode the loader reported.</summary>
        public string StereoModeName => _stereoMode;

        /// <summary>True only when the loader is active and rendering per eye.</summary>
        public bool IsStereo => StereoMode.IsStereo(_stereoMode);

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass _pluginClass;
#endif

        private void Awake()
        {
            _camera = GetComponent<Camera>();
            _awakeAt = Time.unscaledTime;
            ConfigureCamera();
            BuildMinimalScene();
            Debug.Log(
                "[WmrStereo] player hosted; camera=" +
                (_camera != null ? _camera.stereoTargetEye.ToString() : "missing")
            );
        }

        private void ConfigureCamera()
        {
            if (_camera == null) return;
            // The single camera renders both eyes; the VITURE loader decides
            // how (single-pass instanced / multi-pass) when it initialises.
            _camera.stereoTargetEye = StereoTargetEyeMask.Both;
            _camera.clearFlags = CameraClearFlags.SolidColor;
            _camera.backgroundColor = new Color(0.02f, 0.02f, 0.04f, 1f);
        }

        /// <summary>
        /// Three cubes on the forward axis. Their separation at different
        /// depths is the visible proof that each eye gets its own image; an
        /// empty clear-colour frame would look the same in mono.
        /// </summary>
        private void BuildMinimalScene()
        {
            if (_contentBuilt) return;
            _contentBuilt = true;

            var lightObject = new GameObject("WmrStereoLight");
            var light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1f;
            lightObject.transform.rotation = Quaternion.Euler(45f, -30f, 0f);

            CreateDepthMarker("WmrStereoNear", 1.5f);
            CreateDepthMarker("WmrStereoMid", 2.5f);
            CreateDepthMarker("WmrStereoFar", 3.5f);
        }

        private static void CreateDepthMarker(string name, float depth)
        {
            var marker = GameObject.CreatePrimitive(PrimitiveType.Cube);
            marker.name = name;
            marker.transform.position = new Vector3(0f, 0f, depth);
            marker.transform.localScale = new Vector3(0.15f, 0.15f, 0.15f);
        }

        private void Start()
        {
            BeginSession();
            _sessionBegun = true;
        }

        // A Unity player is constructed once per process; `stop` only detaches
        // its view and a later `start` re-attaches and resumes the same player.
        // Unity reports that resume as OnApplicationPause(false), so it is the
        // session boundary: every start re-reports the stage ladder instead of
        // leaving the host with the first session's evidence. The staged scene
        // is already built, so a new session only has to re-arm the reports.
        private void OnApplicationPause(bool paused)
        {
            if (paused || !_sessionBegun) return;
            BeginSession();
        }

        private void BeginSession()
        {
            _loaderReported = false;
            _firstFrameReported = false;
            _timeoutReported = false;
            _stereoMode = StereoMode.Unknown;
            _awakeAt = Time.unscaledTime;
            if (_camera == null)
            {
                _camera = GetComponent<Camera>();
            }
            ConfigureCamera();
            Report(StereoStage.PlayerHosted, StereoMode.Unknown);
            StartCoroutine(ReportFirstFrameAfterLoader());
        }

        private void Update()
        {
            float elapsed = Time.unscaledTime - _awakeAt;
            if (!_loaderReported)
            {
                if (XRSettings.isDeviceActive)
                {
                    _loaderReported = true;
                    _stereoMode = StereoMode.FromRenderingMode((int)XRSettings.stereoRenderingMode);
                    Report(StereoStage.LoaderStarted, _stereoMode);
                    if (!IsStereo)
                    {
                        Debug.LogWarning(
                            "[WmrStereo] XR loader is active but stereo mode is " + _stereoMode
                        );
                    }
                }
                else if (elapsed > loaderTimeoutSeconds && !_timeoutReported)
                {
                    _timeoutReported = true;
                    ReportError(
                        "unavailable",
                        "The VITURE XR loader did not start: " +
                        StereoDiagnostics.Format(StereoStage.LoaderStarted, _stereoMode, true) +
                        "; check XR Plug-in Management (VITURE loader assigned, " +
                        "Initialize XR on Startup enabled)."
                    );
                    return;
                }
            }

            if (_loaderReported && !_firstFrameReported && !_timeoutReported &&
                elapsed > firstFrameTimeoutSeconds)
            {
                _timeoutReported = true;
                ReportError(
                    "unavailable",
                    "No rendered frame after " + firstFrameTimeoutSeconds + "s: " +
                    StereoDiagnostics.Format(StereoStage.FirstFrame, _stereoMode, true)
                );
            }
        }

        // End-of-frame is a pipeline-neutral signal: it fires for the Built-in
        // pipeline and for URP alike, unlike OnPostRender. The boot frame is
        // skipped because the loader has not been started yet; the report is
        // the first frame produced in stereo, which is what a tester needs.
        private IEnumerator ReportFirstFrameAfterLoader()
        {
            while (!_firstFrameReported && !_timeoutReported)
            {
                yield return new WaitForEndOfFrame();
                if (_firstFrameReported || _timeoutReported || !_loaderReported) continue;
                _firstFrameReported = true;
                Report(StereoStage.FirstFrame, _stereoMode);
                Debug.Log(
                    "[WmrStereo] first frame: " +
                    StereoDiagnostics.Format(StereoStage.FirstFrame, _stereoMode, true)
                );
            }
        }

        private void Report(string stage, string stereoMode)
        {
            if (!reportToHost) return;
#if UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                GetPluginClass()?.CallStatic("onUnityStage", stage, stereoMode);
            }
            catch (Exception)
            {
                // Running outside the Flutter host; the log line is the report.
            }
#endif
        }

        private void ReportError(string code, string message)
        {
            Debug.LogError("[WmrStereo] " + code + ": " + message);
            if (!reportToHost) return;
#if UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                GetPluginClass()?.CallStatic("onUnityError", code, message);
            }
            catch (Exception)
            {
                // Running outside the Flutter host.
            }
#endif
        }

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass GetPluginClass()
        {
            if (_pluginClass == null)
            {
                _pluginClass = new AndroidJavaClass(ViturePluginClass);
            }
            return _pluginClass;
        }
#endif
    }
}
