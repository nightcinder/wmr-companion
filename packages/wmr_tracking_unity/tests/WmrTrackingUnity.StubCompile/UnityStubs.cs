// Minimal stubs so the Unity-dependent unified bridge can be compiled outside
// Unity. They model only the members this project uses; they are not a Unity
// emulator and do not validate Unity API signatures.

using System;

namespace UnityEngine
{
    public class Object
    {
    }

    public class GameObject : Object
    {
        public void SetActive(bool value)
        {
        }

        public void SendMessage(string methodName, object value, SendMessageOptions options)
        {
        }
    }

    public enum SendMessageOptions
    {
        RequireReceiver = 0,
        DontRequireReceiver = 1,
    }

    public class MonoBehaviour : Object
    {
        public GameObject gameObject { get; } = new GameObject();

        public bool enabled { get; set; } = true;

        protected static void DontDestroyOnLoad(Object target)
        {
        }

        public T GetComponent<T>() where T : class => null;

        public T[] GetComponentsInChildren<T>(bool includeInactive) where T : class =>
            Array.Empty<T>();
    }

    public static class Debug
    {
        public static void Log(object message)
        {
        }

        public static void LogWarning(object message)
        {
        }

        public static void LogError(object message)
        {
        }
    }

    public static class JsonUtility
    {
        public static T FromJson<T>(string json) => default(T);
    }

    public sealed class AndroidJavaClass : IDisposable
    {
        public AndroidJavaClass(string className)
        {
        }

        public void CallStatic(string methodName, params object[] args)
        {
        }

        public void Dispose()
        {
        }
    }

    [AttributeUsage(AttributeTargets.Field)]
    public sealed class SerializeField : Attribute
    {
    }

    [AttributeUsage(AttributeTargets.Class, AllowMultiple = true)]
    public sealed class RequireComponent : Attribute
    {
        public RequireComponent(Type requiredComponent)
        {
        }
    }

    [AttributeUsage(AttributeTargets.Class)]
    public sealed class DisallowMultipleComponent : Attribute
    {
    }

    [AttributeUsage(AttributeTargets.Field)]
    public sealed class MinAttribute : Attribute
    {
        public MinAttribute(float min)
        {
        }
    }
}

namespace UnityEngine.XR.Management
{
    public class XRLoader
    {
    }

    public class XRManagerSettings
    {
        public XRLoader activeLoader { get; set; }

        public bool automaticLoading { get; set; }

        public bool automaticRunning { get; set; }

        public System.Collections.Generic.List<XRLoader> activeLoaders { get; } =
            new System.Collections.Generic.List<XRLoader>();

        public bool TrySetLoaders(System.Collections.Generic.List<XRLoader> loaders) => true;

        public void InitializeLoaderSync()
        {
        }

        public void StartSubsystems()
        {
        }

        public void StopSubsystems()
        {
        }

        public void DeinitializeLoader()
        {
        }
    }

    public class XRGeneralSettings
    {
        public static XRGeneralSettings Instance { get; set; } = new XRGeneralSettings();

        public XRManagerSettings Manager { get; } = new XRManagerSettings();
    }
}

namespace OnyxLens.WmrTrackingViture
{
    public class VitureTrackingRelayBridge : UnityEngine.MonoBehaviour
    {
        public bool IsRunning { get; set; }

        public event Action<string> FrameEmitted;

        public event Action<string, string> ErrorReported;

        public void OnCommand(string json)
        {
            FrameEmitted?.Invoke(json);
            ErrorReported?.Invoke("stub", "stub");
        }
    }
}

namespace OnyxLens.WmrTrackingXreal
{
    public class XrealTrackingRelayBridge : UnityEngine.MonoBehaviour
    {
        public bool IsRunning { get; set; }

        public event Action<string> FrameEmitted;

        public event Action<string, string> ErrorReported;

        public void OnCommand(string json)
        {
            FrameEmitted?.Invoke(json);
            ErrorReported?.Invoke("stub", "stub");
        }
    }
}
