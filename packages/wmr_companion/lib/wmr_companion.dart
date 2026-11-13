/// Public API of the WMR companion facade.
///
/// Everything a host app needs is exported here. `lib/src/` is internal and
/// must not be imported directly.
library;

export 'package:vector_math/vector_math_64.dart' show Quaternion;

export 'package:wmr_core/ble/ble_transport.dart' show BleTransport;
export 'package:wmr_core/domain/axis_mapping.dart' show AxisMapping;
export 'package:wmr_core/domain/droiddeck_xr_sink.dart'
    show
        DroidDeckXrClaim,
        DroidDeckXrHand,
        DroidDeckXrHidPeripheral,
        DroidDeckXrProtocol,
        DroidDeckXrSink,
        DroidDeckXrTransport,
        droidDeckMonotonicNs,
        encodeDroidDeckXrClaim,
        encodeDroidDeckXrInput;
export 'package:wmr_core/domain/gamepad.dart'
    show
        GamepadButton,
        GamepadConfig,
        GamepadState,
        HandInput,
        TiltConfig,
        TiltTarget,
        TrackpadRole;
export 'package:wmr_core/domain/hand_pipeline.dart'
    show FilterKind, FilterTuning;
export 'package:wmr_core/domain/imu_calibration.dart' show ImuCalibration;
export 'package:wmr_core/domain/loss_window.dart' show LossWindowStats;
export 'package:wmr_core/domain/stick_centre.dart' show StickConfig;
export 'package:wmr_core/domain/tick_timer.dart' show DtStats;
export 'package:wmr_core/protocol/config_block.dart' show ConfigState;
export 'package:wmr_core/protocol/controller_control.dart'
    show
        ControllerAddressSource,
        ControllerCommand,
        ControllerDiscoveryState,
        ControllerModel,
        ControllerResult,
        ControllerStatusV2,
        HandControllerStatus;
export 'package:wmr_core/protocol/decoded_record.dart'
    show
        DecodedRecord,
        wmrBtnBtPairing,
        wmrBtnHome,
        wmrBtnMenu,
        wmrBtnSqueeze,
        wmrBtnThumbstickClick,
        wmrBtnTrackpadClick,
        wmrBtnTrackpadTouch;
export 'package:wmr_core/protocol/firmware_version.dart'
    show WmrBridgeFeature, WmrBridgeFeatures, WmrProtocolVersion;
export 'package:wmr_core/protocol/wmr_fragment.dart' show WmrFrame;
export 'package:wmr_core/services/config_client.dart'
    show ConfigReadFailure, ConfigReadResult;
export 'package:wmr_core/services/controller_control_client.dart'
    show ControllerCommandOutcome;
export 'package:wmr_core/services/controller_service.dart'
    show DecodedStats, StreamMode;
export 'package:wmr_core/services/droiddeck_xr_transport.dart'
    show
        DroidDeckXrTransportException,
        DroidDeckXrUdpTransport,
        DroidDeckXrUnixTransport,
        openDroidDeckXrTransport,
        readDroidDeckXrToken;
export 'package:wmr_core/services/echo_client.dart'
    show EchoFailure, EchoResult, EchoSample;
export 'package:wmr_tracking/wmr_tracking.dart';
export 'package:wmr_ws/wmr_ws.dart'
    show WmrWsDiscovery, WmrWsEndpoint, WmrWsTransport;

export 'src/companion.dart';
export 'src/composite_transport.dart';
export 'src/config.dart';
export 'src/errors.dart';
export 'src/models.dart';
