// Minimal stubs so the Unity-dependent unified bridge can be compiled outside
// Unity. They model only the members this project uses; they are not a Unity
// emulator and do not validate Unity API signatures.

using System;
using System.Collections;

namespace UnityEngine
{
    public class Object
    {
        public string name { get; set; }
    }

    public class GameObject : Object
    {
        public GameObject()
        {
        }

        public GameObject(string name)
        {
            this.name = name;
        }

        public Transform transform { get; } = new Transform();

        public void SetActive(bool value)
        {
        }

        public void SendMessage(string methodName, object value, SendMessageOptions options)
        {
        }

        public static GameObject CreatePrimitive(PrimitiveType type) => new GameObject();

        public T AddComponent<T>() where T : class, new() => new T();
    }

    public enum PrimitiveType
    {
        Sphere = 0,
        Capsule = 1,
        Cylinder = 2,
        Cube = 3,
        Plane = 4,
        Quad = 5,
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

        public Coroutine StartCoroutine(IEnumerator routine) => new Coroutine();
    }

    public class Coroutine
    {
    }

    public sealed class WaitForEndOfFrame
    {
    }

    public class Behaviour : Object
    {
        public bool enabled { get; set; } = true;

        public GameObject gameObject { get; } = new GameObject();
    }

    public class Light : Behaviour
    {
        public LightType type { get; set; }

        public float intensity { get; set; } = 1f;
    }

    public enum LightType
    {
        Spot = 0,
        Directional = 1,
        Point = 2,
        Area = 3,
    }

    public sealed class Camera : Object
    {
        public static Camera main { get; set; }

        public StereoTargetEyeMask stereoTargetEye { get; set; }

        public CameraClearFlags clearFlags { get; set; }

        public Color backgroundColor { get; set; }

        public Transform transform { get; } = new Transform();
    }

    public enum CameraClearFlags
    {
        Skybox = 1,
        Color = 2,
        SolidColor = 2,
        Depth = 3,
        Nothing = 4,
    }

    public struct Color
    {
        public float r;
        public float g;
        public float b;
        public float a;

        public Color(float r, float g, float b, float a)
        {
            this.r = r;
            this.g = g;
            this.b = b;
            this.a = a;
        }
    }

    public static class Time
    {
        public static float unscaledTime { get; set; }
    }

    public class Transform : Object
    {
        public Vector3 position { get; set; }

        public Vector3 localScale { get; set; }

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

        public static Quaternion Euler(float x, float y, float z) =>
            new Quaternion(0f, 0f, 0f, 1f);
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
