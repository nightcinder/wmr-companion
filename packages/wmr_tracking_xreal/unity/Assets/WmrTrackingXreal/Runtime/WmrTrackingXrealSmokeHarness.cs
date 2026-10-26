// Minimal smoke-scene driver for the XREAL Unity-as-a-Library relay.
//
// Attach next to XrealTrackingRelayBridge on the "WmrTrackingRelay"
// GameObject. It logs relay frames and pause/resume, and in the editor it can
// send the same versioned `start` envelope that Kotlin sends through
// UnityPlayer.UnitySendMessage. It performs no rendering and no general Unity UI.
//
// Player builds never start tracking from the scene: the Android host owns
// start/stop so the vendor session stays inside its CAMERA-permission and
// default-off flow.

using UnityEngine;

namespace OnyxLens.WmrTrackingXreal
{
    [DisallowMultipleComponent]
    [RequireComponent(typeof(XrealTrackingRelayBridge))]
    public sealed class WmrTrackingXrealSmokeHarness : MonoBehaviour
    {
        private const string RelayMethod = "OnCommand";

        // Must stay in sync with XrealRelayCommandBuilder.start().
        private const string StartCommand = "{\"v\":1,\"cmd\":\"start\",\"vendor\":\"xreal\"}";

        // Editor-only convenience so the scene can be played without a host.
        // Ignored in player builds; the Android host drives `start`.
        [SerializeField] private bool autoStart = false;
        [SerializeField, Min(1)] private int logEveryNFrames = 30;

        private XrealTrackingRelayBridge _bridge;
        private int _frames;
        private int _pauseCount;

        /// <summary>Number of relay frames observed by this harness.</summary>
        public int FramesObserved => _frames;

        private void Awake()
        {
            _bridge = GetComponent<XrealTrackingRelayBridge>();
            if (_bridge == null)
            {
                Debug.LogError(
                    "[WmrTrackingXrealSmoke] XrealTrackingRelayBridge is missing"
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
            SendStart();
#else
            Debug.Log(
                "[WmrTrackingXrealSmoke] autoStart ignored in player builds; the host drives start"
            );
#endif
        }

        private void OnDestroy()
        {
            if (_bridge == null) return;
            _bridge.FrameEmitted -= OnFrameEmitted;
            _bridge.ErrorReported -= OnErrorReported;
        }

        /// <summary>Sends the relay `start` command through the bridge method.</summary>
        public void SendStart()
        {
            if (_bridge.IsRunning)
            {
                Debug.Log("[WmrTrackingXrealSmoke] relay already running; start skipped");
                return;
            }
            gameObject.SendMessage(RelayMethod, StartCommand, SendMessageOptions.RequireReceiver);
            Debug.Log("[WmrTrackingXrealSmoke] sent start: " + StartCommand);
        }

        private void OnFrameEmitted(string frameJson)
        {
            _frames++;
            if (_frames == 1)
            {
                Debug.Log("[WmrTrackingXrealSmoke] first frame: " + frameJson);
                return;
            }
            if (_frames % logEveryNFrames != 0) return;
            Debug.Log(
                "[WmrTrackingXrealSmoke] frame " + _frames +
                " bytes=" + frameJson.Length +
                " hasHead=" + frameJson.Contains("\"head\"") +
                " hasHands=" + frameJson.Contains("\"hands\"")
            );
        }

        private void OnErrorReported(string code, string message)
        {
            Debug.LogError(
                "[WmrTrackingXrealSmoke] relay error code=" + code + " message=" + message
            );
        }

        private void OnApplicationPause(bool pauseStatus)
        {
            if (pauseStatus)
            {
                _pauseCount++;
                Debug.Log(
                    "[WmrTrackingXrealSmoke] paused after " + _frames +
                    " frame(s); relayRunning=" + _bridge.IsRunning
                );
                return;
            }

            Debug.Log(
                "[WmrTrackingXrealSmoke] resumed after " + _pauseCount +
                " pause(s); frames=" + _frames + " relayRunning=" + _bridge.IsRunning
            );
            // The host owns start/stop, so a session the host stopped stays
            // stopped. Never restart vendor tracking from the scene.
        }
    }
}
