// Minimal smoke-scene driver for the VITURE Unity-as-a-Library relay.
//
// Attach next to VitureTrackingRelayBridge on the "WmrTrackingRelay"
// GameObject. It logs relay frames and pause/resume, and in the editor it can
// send the same versioned `start` envelope that Kotlin sends through
// UnityPlayer.UnitySendMessage. It performs no rendering and no general Unity UI.
//
// Player builds never start tracking from the scene: the Android host owns
// start/stop so the vendor session stays inside its CAMERA-permission and
// default-off flow.

using UnityEngine;

namespace OnyxLens.WmrTrackingViture
{
    [DisallowMultipleComponent]
    [RequireComponent(typeof(VitureTrackingRelayBridge))]
    public sealed class WmrTrackingVitureSmokeHarness : MonoBehaviour
    {
        private const string RelayMethod = "OnCommand";

        // Must stay in sync with VitureRelayCommandBuilder.start().
        private const string StartCommand =
            "{\"v\":1,\"cmd\":\"start\",\"vendor\":\"viture\"," +
            "\"options\":{\"filter_mode\":\"responsive\",\"aim_sensitivity\":\"high\"}}";

        // Editor-only convenience so the scene can be played without a host.
        // Ignored in player builds; the Android host drives `start`.
        [SerializeField] private bool autoStart = false;
        [SerializeField, Min(1)] private int logEveryNFrames = 30;

        private VitureTrackingRelayBridge _bridge;
        private int _frames;
        private int _pauseCount;

        /// <summary>Number of relay frames observed by this harness.</summary>
        public int FramesObserved => _frames;

        private void Awake()
        {
            _bridge = GetComponent<VitureTrackingRelayBridge>();
            if (_bridge == null)
            {
                Debug.LogError(
                    "[WmrTrackingVitureSmoke] VitureTrackingRelayBridge is missing"
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
                "[WmrTrackingVitureSmoke] autoStart ignored in player builds; the host drives start"
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
                Debug.Log("[WmrTrackingVitureSmoke] relay already running; start skipped");
                return;
            }
            gameObject.SendMessage(RelayMethod, StartCommand, SendMessageOptions.RequireReceiver);
            Debug.Log("[WmrTrackingVitureSmoke] sent start: " + StartCommand);
        }

        private void OnFrameEmitted(string frameJson)
        {
            _frames++;
            if (_frames == 1)
            {
                Debug.Log("[WmrTrackingVitureSmoke] first frame: " + frameJson);
                return;
            }
            if (_frames % logEveryNFrames != 0) return;
            Debug.Log(
                "[WmrTrackingVitureSmoke] frame " + _frames +
                " bytes=" + frameJson.Length +
                " hasHead=" + frameJson.Contains("\"head\"") +
                " hasHands=" + frameJson.Contains("\"hands\"")
            );
        }

        private void OnErrorReported(string code, string message)
        {
            Debug.LogError(
                "[WmrTrackingVitureSmoke] relay error code=" + code + " message=" + message
            );
        }

        private void OnApplicationPause(bool pauseStatus)
        {
            if (pauseStatus)
            {
                _pauseCount++;
                Debug.Log(
                    "[WmrTrackingVitureSmoke] paused after " + _frames +
                    " frame(s); relayRunning=" + _bridge.IsRunning
                );
                return;
            }

            Debug.Log(
                "[WmrTrackingVitureSmoke] resumed after " + _pauseCount +
                " pause(s); frames=" + _frames + " relayRunning=" + _bridge.IsRunning
            );
            // The host owns start/stop, so a session the host stopped stays
            // stopped. Never restart vendor tracking from the scene.
        }
    }
}
