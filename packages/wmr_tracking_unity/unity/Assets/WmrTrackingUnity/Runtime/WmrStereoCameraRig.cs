// The minimal stereo scene for the VITURE UaaL player (ONY-612).
//
// Attach to the Main Camera of the exported scene. It assumes the camera is
// already the XR/stereo target, keeps it targeting both eyes, builds a small
// depth ladder so a tester can see one coherent 3D image, and reports the
// startup stages to Kotlin through the selected vendor plugin's
// `onUnityStage` entry point (VITURE by default, XREAL when configured).
//
// The VITURE loader owns the actual stereo presentation mode; this script only
// reads it back. It never switches a mono player into stereo at runtime.
//
// The loader/stereo expectations are VITURE-only. In a unified scene the rig
// stays inert until a VITURE session is running, so an XREAL session (or an
// idle scene before any start) never reports the VITURE 10 s loader timeout.

using System;
using System.Collections;
using OnyxLens.WmrTrackingUnity.Dispatch;
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
        private const string XrealPluginClass =
            "com.onyxlens.wmr_tracking_xreal.WmrTrackingXrealPlugin";

        [SerializeField] private bool reportToHost = true;

        // Which Kotlin plugin receives the stage/error reports. A standalone
        // XREAL scene sets this to "xreal"; the unified scene follows the
        // vendor selected on the unified bridge.
        [SerializeField] private string stageVendor = VendorNames.Viture;

        // Optional; found automatically. Present in the unified scene, absent
        // in the per-vendor projects.
        [SerializeField] private WmrTrackingUnifiedBridge unifiedBridge;

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
        private bool _vitureSession;
        private int _sessionId;
        private float _awakeAt;
        private string _stereoMode = StereoMode.Unknown;

        /// <summary>Wire name of the last stereo mode the loader reported.</summary>
        public string StereoModeName => _stereoMode;

        /// <summary>True only when the loader is active and rendering per eye.</summary>
        public bool IsStereo => StereoMode.IsStereo(_stereoMode);

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass _viturePluginClass;
        private AndroidJavaClass _xrealPluginClass;
#endif

        private void Awake()
        {
            if (unifiedBridge == null)
            {
                unifiedBridge = FindObjectOfType<WmrTrackingUnifiedBridge>();
            }
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
            _sessionId++;
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
            // Reported even before a vendor is selected: Kotlin uses this
            // stage to replay the pending `start` command.
            Report(StereoStage.PlayerHosted, StereoMode.Unknown);
            if (_vitureSession)
            {
                StartCoroutine(ReportFirstFrameAfterLoader(_sessionId));
            }
        }

        private bool IsXrealStageVendor() =>
            string.Equals(stageVendor, VendorNames.Xreal, StringComparison.OrdinalIgnoreCase);

        private string EffectiveStageVendor()
        {
            if (unifiedBridge != null)
            {
                VendorBackend selected = unifiedBridge.SelectedVendor;
                if (selected != VendorBackend.None)
                {
                    return VendorNames.ToWireName(selected);
                }
            }
            return IsXrealStageVendor() ? VendorNames.Xreal : VendorNames.Viture;
        }

        private bool IsVitureSession()
        {
            if (unifiedBridge == null)
            {
                // Per-vendor project: the rig is VITURE unless configured for
                // an XREAL-only scene.
                return !IsXrealStageVendor();
            }
            return unifiedBridge.IsRunning && unifiedBridge.ActiveVendor == VendorBackend.Viture;
        }

        private void Update()
        {
            if (!IsVitureSession())
            {
                _vitureSession = false;
                return;
            }
            if (!_vitureSession)
            {
                // First VITURE frame of this session: start the loader clock
                // now, not at player creation. Otherwise an idle scene or a
                // late start reports a spurious 10 s timeout.
                _vitureSession = true;
                _sessionId++;
                _loaderReported = false;
                _firstFrameReported = false;
                _timeoutReported = false;
                _stereoMode = StereoMode.Unknown;
                _awakeAt = Time.unscaledTime;
                StartCoroutine(ReportFirstFrameAfterLoader(_sessionId));
            }
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
        private IEnumerator ReportFirstFrameAfterLoader(int sessionId)
        {
            while (sessionId == _sessionId && _vitureSession &&
                   !_firstFrameReported && !_timeoutReported)
            {
                yield return new WaitForEndOfFrame();
                if (sessionId != _sessionId || !_vitureSession ||
                    _firstFrameReported || _timeoutReported || !_loaderReported) continue;
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
                GetPluginClass(EffectiveStageVendor())
                    ?.CallStatic("onUnityStage", stage, stereoMode);
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
                GetPluginClass(EffectiveStageVendor())
                    ?.CallStatic("onUnityError", code, message);
            }
            catch (Exception)
            {
                // Running outside the Flutter host.
            }
#endif
        }

#if UNITY_ANDROID && !UNITY_EDITOR
        private AndroidJavaClass GetPluginClass(string vendor)
        {
            if (string.Equals(vendor, VendorNames.Xreal, StringComparison.OrdinalIgnoreCase))
            {
                if (_xrealPluginClass == null)
                {
                    _xrealPluginClass = new AndroidJavaClass(XrealPluginClass);
                }
                return _xrealPluginClass;
            }
            if (_viturePluginClass == null)
            {
                _viturePluginClass = new AndroidJavaClass(ViturePluginClass);
            }
            return _viturePluginClass;
        }
#endif
    }
}
