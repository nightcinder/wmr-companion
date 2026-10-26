// Minimal smoke-scene driver for the unified Unity-as-a-Library relay.
//
// Attach next to WmrTrackingUnifiedBridge on the "WmrTrackingRelay"
// GameObject. It logs relay frames and pause/resume, and in the editor it can
// send the same versioned `start` envelope that Kotlin sends through
// UnityPlayer.UnitySendMessage. It performs no rendering and no general Unity UI.
//
// Player builds never start tracking from the scene: the Android host owns
// start/stop so the vendor session stays inside its CAMERA-permission and
// default-off flow.

using OnyxLens.WmrTrackingUnity.Dispatch;
using UnityEngine;

namespace OnyxLens.WmrTrackingUnity
{
    [DisallowMultipleComponent]
    [RequireComponent(typeof(WmrTrackingUnifiedBridge))]
    public sealed class WmrTrackingUnifiedSmokeHarness : MonoBehaviour
    {
        private const string RelayMethod = "OnCommand";

        // Must stay in sync with the per-vendor RelayCommandBuilder.start().
        private const string VitureStartCommand =
            "{\"v\":1,\"cmd\":\"start\",\"vendor\":\"viture\"," +
            "\"options\":{\"filter_mode\":\"responsive\",\"aim_sensitivity\":\"high\"}}";
        private const string XrealStartCommand =
            "{\"v\":1,\"cmd\":\"start\",\"vendor\":\"xreal\"}";

        // Editor-only convenience so the scene can be played without a host.
        // Ignored in player builds; the Android host drives `start`.
        [SerializeField] private bool autoStart = false;
        [SerializeField] private string autoStartVendor = "viture";
        [SerializeField, Min(1)] private int logEveryNFrames = 30;

        private WmrTrackingUnifiedBridge _bridge;
        private int _frames;
        private int _pauseCount;

        /// <summary>Number of relay frames observed by this harness.</summary>
        public int FramesObserved => _frames;

        private void Awake()
        {
            _bridge = GetComponent<WmrTrackingUnifiedBridge>();
            if (_bridge == null)
            {
                Debug.LogError(
                    "[WmrTrackingUnitySmoke] WmrTrackingUnifiedBridge is missing"
                );
                enabled = false;
                return;
            }
            _bridge.FrameEmitted += OnFrameEmitted;
            _bridge.ErrorReported += OnErrorReported;
        }

        private void Start()
        {
            if (!autoStart) return;
#if UNITY_EDITOR
            SendStart(autoStartVendor);
#else
            Debug.Log(
                "[WmrTrackingUnitySmoke] autoStart ignored in player builds; " +
                "the host drives start"
            );
#endif
        }

        private void OnDestroy()
        {
            if (_bridge == null) return;
            _bridge.FrameEmitted -= OnFrameEmitted;
            _bridge.ErrorReported -= OnErrorReported;
        }

        /// <summary>Sends a relay `start` command for the requested vendor.</summary>
        public void SendStart(string vendor)
        {
            if (_bridge.IsRunning)
            {
                Debug.Log(
                    "[WmrTrackingUnitySmoke] relay already running vendor=" +
                    VendorNames.ToWireName(_bridge.ActiveVendor) +
                    "; start skipped"
                );
                return;
            }
            if (!VendorNames.TryParse(vendor, out VendorBackend backend))
            {
                Debug.LogError(
                    "[WmrTrackingUnitySmoke] unknown vendor '" + vendor + "'"
                );
                return;
            }
            string command = backend == VendorBackend.Xreal
                ? XrealStartCommand
                : VitureStartCommand;
            gameObject.SendMessage(RelayMethod, command, SendMessageOptions.RequireReceiver);
            Debug.Log("[WmrTrackingUnitySmoke] sent start: " + command);
        }

        private void OnFrameEmitted(string frameJson)
        {
            _frames++;
            if (_frames == 1)
            {
                Debug.Log("[WmrTrackingUnitySmoke] first frame: " + frameJson);
                return;
            }
            if (_frames % logEveryNFrames != 0) return;
            Debug.Log(
                "[WmrTrackingUnitySmoke] frame " + _frames +
                " bytes=" + frameJson.Length +
                " vendor=" + VendorNames.ToWireName(_bridge.ActiveVendor) +
                " hasHead=" + frameJson.Contains("\"head\"") +
                " hasHands=" + frameJson.Contains("\"hands\"")
            );
        }

        private void OnErrorReported(string code, string message)
        {
            Debug.LogError(
                "[WmrTrackingUnitySmoke] relay error code=" + code +
                " message=" + message
            );
        }

        private void OnApplicationPause(bool pauseStatus)
        {
            if (pauseStatus)
            {
                _pauseCount++;
                Debug.Log(
                    "[WmrTrackingUnitySmoke] paused after " + _frames +
                    " frame(s); relayRunning=" + _bridge.IsRunning
                );
                return;
            }

            Debug.Log(
                "[WmrTrackingUnitySmoke] resumed after " + _pauseCount +
                " pause(s); frames=" + _frames +
                " relayRunning=" + _bridge.IsRunning
            );
            // The host owns start/stop, so a session the host stopped stays
            // stopped. Never restart vendor tracking from the scene.
        }
    }
}
