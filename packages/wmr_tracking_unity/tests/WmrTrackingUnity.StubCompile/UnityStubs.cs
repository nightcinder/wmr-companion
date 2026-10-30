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

    public enum StereoTargetEyeMask
    {
        None = 0,
        Left = 1,
        Right = 2,
        Both = 3,
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

    public class Camera : Object
    {
        public static Camera main { get; set; }

        public StereoTargetEyeMask stereoTargetEye { get; set; }

        public Transform transform { get; } = new Transform();
    }

    public class Transform : Object
    {
        public Vector3 position { get; set; }

        public Quaternion rotation { get; set; }
    }

    public struct Vector3
    {
        public float x;
        public float y;
        public float z;

        public Vector3(float x, float y, float z)
        {
            this.x = x;
            this.y = y;
            this.z = z;
        }
    }

    public struct Quaternion
    {
        public float x;
        public float y;
        public float z;
        public float w;

        public Quaternion(float x, float y, float z, float w)
        {
            this.x = x;
            this.y = y;
            this.z = z;
            this.w = w;
        }
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

namespace UnityEngine.XR
{
    public static class XRSettings
    {
        public enum StereoRenderingMode
        {
            MultiPass = 0,
            SinglePass = 1,
            SinglePassInstanced = 2,
        }

        public static bool isDeviceActive { get; set; } = true;

        // Read-only in Unity 6000.0: a setter here would hide CS0200.
        public static StereoRenderingMode stereoRenderingMode { get; }
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

        public bool TrySetLoaders(System.Collections.Generic.List<XRLoader> loaders)
        {
            activeLoaders.Clear();
            activeLoaders.AddRange(loaders);
            return true;
        }

        public void InitializeLoaderSync()
        {
            // XR Management initialises the first assigned loader; it keeps
            // only one active loader per process.
            if (activeLoader == null && activeLoaders.Count > 0)
            {
                activeLoader = activeLoaders[0];
            }
        }

        public void StartSubsystems()
        {
        }

        public void StopSubsystems()
        {
        }

        public void DeinitializeLoader()
        {
            activeLoader = null;
        }
    }

    public class XRGeneralSettings
    {
        public static XRGeneralSettings Instance { get; set; } = new XRGeneralSettings();

        public XRManagerSettings Manager { get; } = new XRManagerSettings();
    }
}
