// Unity-independent vendor dispatch for the unified WmrTrackingRelay.
//
// The relay command envelope is unchanged:
//   {"v":1,"cmd":"start"|"stop"|"dispose"|"recenter"|"configure",
//    "vendor":"viture"|"xreal", "options":{...}}
//
// This file deliberately has no UnityEngine dependency so the routing rules can
// be compiled and tested outside Unity. The MonoBehaviour adapter owns the
// vendor bridges and reports rejection strings through the existing
// `onUnityError` contract.

using System;

namespace OnyxLens.WmrTrackingUnity.Dispatch
{
    /// <summary>Vendor backend selected by the relay `vendor` field.</summary>
    public enum VendorBackend
    {
        None = 0,
        Viture = 1,
        Xreal = 2,
    }

    public enum RelayCommandKind
    {
        Configure,
        Start,
        Stop,
        Recenter,
        Dispose,
        Reject,
    }

    /// <summary>
    /// Parsed command plus the vendor that should receive it. Rejections carry
    /// the same `(code, message)` shape as `onUnityError`.
    /// </summary>
    public readonly struct RelayDecision
    {
        public RelayDecision(
            RelayCommandKind kind,
            VendorBackend target,
            string errorCode,
            string errorMessage
        )
        {
            Kind = kind;
            Target = target;
            ErrorCode = errorCode ?? string.Empty;
            ErrorMessage = errorMessage ?? string.Empty;
        }

        public RelayCommandKind Kind { get; }

        public VendorBackend Target { get; }

        public string ErrorCode { get; }

        public string ErrorMessage { get; }

        public bool IsRejected => Kind == RelayCommandKind.Reject;

        public static RelayDecision Reject(string code, string message) =>
            new RelayDecision(RelayCommandKind.Reject, VendorBackend.None, code, message);
    }

    /// <summary>Wire names shared by the Kotlin builders and the Unity bridge.</summary>
    public static class VendorNames
    {
        public const string Viture = "viture";
        public const string Xreal = "xreal";

        /// <summary>
        /// Accepts the exact contract names, case-insensitively and with
        /// surrounding whitespace. No auto-detection happens here: the Kotlin
        /// host decides the vendor from the detected glasses.
        /// </summary>
        public static bool TryParse(string value, out VendorBackend backend)
        {
            backend = VendorBackend.None;
            if (string.IsNullOrEmpty(value)) return false;

            string normalized = value.Trim();
            if (string.Equals(normalized, Viture, StringComparison.OrdinalIgnoreCase))
            {
                backend = VendorBackend.Viture;
                return true;
            }
            if (string.Equals(normalized, Xreal, StringComparison.OrdinalIgnoreCase))
            {
                backend = VendorBackend.Xreal;
                return true;
            }
            return false;
        }

        public static string ToWireName(VendorBackend backend)
        {
            switch (backend)
            {
                case VendorBackend.Viture:
                    return Viture;
                case VendorBackend.Xreal:
                    return Xreal;
                default:
                    return string.Empty;
            }
        }
    }

    /// <summary>
    /// State machine for vendor selection. `Decide` is pure; the adapter calls
    /// `Accepted` only after the vendor bridge accepted the command and, for
    /// `start`, after the vendor loader initialised. `StartFailed` keeps the
    /// selection so the host can retry without sending `configure` again.
    /// </summary>
    public sealed class VendorRelayDispatch
    {
        public VendorBackend SelectedVendor { get; private set; } = VendorBackend.None;

        public VendorBackend RunningVendor { get; private set; } = VendorBackend.None;

        public bool IsRunning => RunningVendor != VendorBackend.None;

        public RelayDecision Decide(string command, string vendor)
        {
            if (string.IsNullOrEmpty(command))
            {
                return RelayDecision.Reject("protocol", "Empty relay command");
            }

            bool vendorProvided = !string.IsNullOrEmpty(vendor);
            VendorBackend requested = VendorBackend.None;
            if (vendorProvided && !VendorNames.TryParse(vendor, out requested))
            {
                return RelayDecision.Reject(
                    "unsupported",
                    "Unknown relay vendor: " + vendor
                );
            }

            switch (command)
            {
                case "configure":
                    if (IsRunning && vendorProvided && requested != RunningVendor)
                    {
                        return RelayDecision.Reject(
                            "busy",
                            "Stop the active vendor before configuring " +
                            VendorNames.ToWireName(requested)
                        );
                    }
                    return new RelayDecision(
                        RelayCommandKind.Configure,
                        vendorProvided
                            ? requested
                            : (IsRunning ? RunningVendor : SelectedVendor),
                        null,
                        null
                    );

                case "start":
                    VendorBackend target = vendorProvided
                        ? requested
                        : (IsRunning ? RunningVendor : SelectedVendor);
                    if (target == VendorBackend.None)
                    {
                        return RelayDecision.Reject(
                            "protocol",
                            "start requires a vendor field or a prior configure"
                        );
                    }
                    if (IsRunning && target != RunningVendor)
                    {
                        return RelayDecision.Reject(
                            "busy",
                            "Stop the active vendor before starting " +
                            VendorNames.ToWireName(target)
                        );
                    }
                    return new RelayDecision(RelayCommandKind.Start, target, null, null);

                case "stop":
                    return new RelayDecision(
                        RelayCommandKind.Stop,
                        RunningVendor,
                        null,
                        null
                    );

                case "recenter":
                    if (!IsRunning)
                    {
                        return RelayDecision.Reject(
                            "unavailable",
                            "recenter requires an active vendor session"
                        );
                    }
                    return new RelayDecision(
                        RelayCommandKind.Recenter,
                        RunningVendor,
                        null,
                        null
                    );

                case "dispose":
                    return new RelayDecision(
                        RelayCommandKind.Dispose,
                        RunningVendor,
                        null,
                        null
                    );

                default:
                    return RelayDecision.Reject(
                        "protocol",
                        "Unknown relay command: " + command
                    );
            }
        }

        /// <summary>Commits a decision whose side effects succeeded.</summary>
        public void Accepted(RelayDecision decision)
        {
            switch (decision.Kind)
            {
                case RelayCommandKind.Configure:
                    if (decision.Target != VendorBackend.None)
                    {
                        SelectedVendor = decision.Target;
                    }
                    break;
                case RelayCommandKind.Start:
                    SelectedVendor = decision.Target;
                    RunningVendor = decision.Target;
                    break;
                case RelayCommandKind.Stop:
                    RunningVendor = VendorBackend.None;
                    break;
                case RelayCommandKind.Dispose:
                    RunningVendor = VendorBackend.None;
                    SelectedVendor = VendorBackend.None;
                    break;
            }
        }

        /// <summary>
        /// Records a `start` that selected the vendor but could not initialise
        /// it. The vendor stays selected, the relay stays stopped.
        /// </summary>
        public void StartFailed(RelayDecision decision)
        {
            if (decision.Kind == RelayCommandKind.Start &&
                decision.Target != VendorBackend.None)
            {
                SelectedVendor = decision.Target;
                RunningVendor = VendorBackend.None;
            }
        }
    }
}
