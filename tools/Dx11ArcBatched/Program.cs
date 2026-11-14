using System.Diagnostics;
using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

internal static class Program
{
    private const int ElementCount = 1024 * 1024;
    private const int ThreadsPerGroup = 256;

    private static int Main(string[] args)
    {
        string? match = GetArg(args, "--match");
        string api = GetArg(args, "--api") ?? "d3d11";
        int seconds = int.TryParse(GetArg(args, "--seconds"), out int parsedSeconds) ? parsedSeconds : 15;
        bool listOnly = args.Contains("--list") || match is null;

        using IDXGIFactory1 factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        List<(int Index, IDXGIAdapter1 Adapter, AdapterDescription1 Description)> adapters = EnumerateAdapters(factory);

        Console.WriteLine("DXGI adapters:");
        foreach ((int index, IDXGIAdapter1 adapter, AdapterDescription1 desc) in adapters)
        {
            Console.WriteLine($"[{index}] {desc.Description}");
            Console.WriteLine($"    vendor=0x{desc.VendorId:X4} device=0x{desc.DeviceId:X4} dedicated_vram={ToGiB(desc.DedicatedVideoMemory):0.00}GiB flags={desc.Flags}");
        }

        if (listOnly)
        {
            return 0;
        }

        (int Index, IDXGIAdapter1 Adapter, AdapterDescription1 Description)? selected =
            adapters.FirstOrDefault(a => a.Description.VendorId == 0x8086 && a.Description.DeviceId == 0x56A0 && a.Description.Description.Contains(match!, StringComparison.OrdinalIgnoreCase));

        if (selected is null || selected.Value.Adapter is null)
        {
            Console.Error.WriteLine($"No adapter matched '{match}'.");
            return 2;
        }

        try
        {
            if (api.Equals("d3d12", StringComparison.OrdinalIgnoreCase))
            {
                TestD3D12CreateDevice(selected.Value.Index, selected.Value.Adapter, selected.Value.Description);
            }
            else
            {
                StressAdapter(selected.Value.Index, selected.Value.Adapter, selected.Value.Description, seconds);
            }
            return 0;
        }
        finally
        {
            foreach ((_, IDXGIAdapter1 adapter, _) in adapters)
            {
                adapter.Dispose();
            }
        }
    }

    private static void TestD3D12CreateDevice(int index, IDXGIAdapter1 adapter, AdapterDescription1 desc)
    {
        Console.WriteLine();
        Console.WriteLine($"Selected [{index}] {desc.Description}");
        Console.WriteLine("API: D3D12CreateDevice");

        Guid id3d12Device = new("189819f1-1db6-4b57-be54-1821339b85f7");
        int[] featureLevels = [0xC100, 0xC000, 0xB100, 0xB000];
        foreach (int featureLevel in featureLevels)
        {
            int hr = D3D12CreateDevice(adapter.NativePointer, featureLevel, ref id3d12Device, out IntPtr device);
            if (hr == 0 && device != IntPtr.Zero)
            {
                Marshal.Release(device);
                Console.WriteLine($"PASS {desc.Description}: D3D12CreateDevice minimum_feature_level=0x{featureLevel:X}");
                return;
            }

            Console.WriteLine($"FAIL {desc.Description}: D3D12CreateDevice minimum_feature_level=0x{featureLevel:X} HRESULT=0x{hr:X8}");
        }

        Environment.ExitCode = 3;
    }

    private static List<(int, IDXGIAdapter1, AdapterDescription1)> EnumerateAdapters(IDXGIFactory1 factory)
    {
        var result = new List<(int, IDXGIAdapter1, AdapterDescription1)>();
        for (uint i = 0; ; i++)
        {
            Result hr = factory.EnumAdapters1(i, out IDXGIAdapter1? adapter);
            if (hr.Failure || adapter is null)
            {
                break;
            }

            AdapterDescription1 desc = adapter.Description1;
            if (!desc.Description.Contains("Basic Render", StringComparison.OrdinalIgnoreCase))
            {
                result.Add(((int)i, adapter, desc));
            }
            else
            {
                adapter.Dispose();
            }
        }

        return result;
    }

    private static void StressAdapter(int index, IDXGIAdapter1 adapter, AdapterDescription1 desc, int seconds)
    {
        Console.WriteLine();
        Console.WriteLine($"Selected [{index}] {desc.Description}");
        Console.WriteLine($"Duration: {seconds}s, 64 dispatches per native D3D11 batch");

        FeatureLevel[] featureLevels =
        [
            FeatureLevel.Level_11_0
        ];

        Result hr = D3D11.D3D11CreateDevice(
            adapter,
            DriverType.Unknown,
            DeviceCreationFlags.None,
            featureLevels,
            out ID3D11Device? device,
            out FeatureLevel featureLevel,
            out ID3D11DeviceContext? context);

        hr.CheckError();
        if (device is null || context is null)
        {
            throw new InvalidOperationException("D3D11CreateDevice returned no device/context.");
        }

        using ID3D11Device ownedDevice = device;
        using ID3D11DeviceContext ownedContext = context;
        using Blob shaderBlob = CompileShader();
        using ID3D11ComputeShader shader = ownedDevice.CreateComputeShader(shaderBlob, null);
        using ID3D11Buffer buffer = ownedDevice.CreateBuffer(
            (uint)(ElementCount * sizeof(uint)),
            BindFlags.UnorderedAccess,
            ResourceUsage.Default,
            CpuAccessFlags.None,
            ResourceOptionFlags.BufferStructured,
            sizeof(uint));
        using ID3D11UnorderedAccessView uav = ownedDevice.CreateUnorderedAccessView(buffer, null);
        using var fenceDevice = ownedDevice.QueryInterface<ID3D11Device5>();
        using var fenceContext = ownedContext.QueryInterface<ID3D11DeviceContext4>();
        using var fence = fenceDevice.CreateFence(0, FenceFlags.None);

        using var completion = new AutoResetEvent(false);
        const int dispatchesPerBatch = 64;

        ownedContext.CSSetShader(shader, null, 0);

        uint groups = (uint)(ElementCount / ThreadsPerGroup);
        var stopwatch = Stopwatch.StartNew();
        long dispatches = 0;
        int lastPrintedSecond = -1;

        var uavs = new[] { uav };
        var initialCounts = new[] { uint.MaxValue };
        while (stopwatch.Elapsed.TotalSeconds < seconds)
        {
            ownedContext.CSSetUnorderedAccessViews(0, 1, uavs, initialCounts);
            for (int batchIndex = 0; batchIndex < dispatchesPerBatch; batchIndex++)
                ownedContext.Dispatch(groups, 1, 1);
            ulong target = (ulong)(dispatches + dispatchesPerBatch);
            fenceContext.Signal(fence, target);
            fence.SetEventOnCompletion(target, completion);
            ownedContext.Flush();
            if (!completion.WaitOne(TimeSpan.FromSeconds(5)))
                throw new TimeoutException("Native D3D11 GPU batch did not complete within 5 seconds.");
            ownedDevice.DeviceRemovedReason.CheckError();
            if (fence.CompletedValue != target)
                throw new InvalidOperationException($"Native D3D11 fence reached {fence.CompletedValue}, expected {target}.");
            dispatches += dispatchesPerBatch;

            int currentSecond = (int)stopwatch.Elapsed.TotalSeconds;
            if (currentSecond != lastPrintedSecond)
            {
                lastPrintedSecond = currentSecond;
                ownedContext.Flush();
                Console.Write($"\rElapsed {stopwatch.Elapsed.TotalSeconds,5:0.0}s, dispatches {dispatches}");
            }
        }

        ownedContext.Flush();
        Console.WriteLine();
        using var readback = ownedDevice.CreateBuffer((uint)(ElementCount * sizeof(uint)), BindFlags.None,
            ResourceUsage.Staging, CpuAccessFlags.Read, ResourceOptionFlags.None, 0);
        ownedContext.CSSetUnorderedAccessViews(0, 1, new ID3D11UnorderedAccessView[] { null! }, initialCounts);
        ownedContext.CopyResource(readback, buffer);
        var mapped = ownedContext.Map(readback, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            int[] indices = [0, ElementCount / 3, ElementCount / 2, ElementCount - 1];
            foreach (int sampleIndex in indices)
            {
                uint actual = unchecked((uint)Marshal.ReadInt32(mapped.DataPointer, sampleIndex * sizeof(uint)));
                uint expected = unchecked((uint)sampleIndex * 747796405u + 2891336453u);
                for (int round = 0; round < 256; round++)
                {
                    expected ^= expected >> 16;
                    expected = unchecked(expected * 2246822519u);
                    expected ^= expected >> 13;
                    expected = unchecked(expected * 3266489917u);
                    expected ^= expected >> 16;
                }
                if (actual != expected)
                    throw new InvalidOperationException($"D3D11 readback mismatch at {sampleIndex}: {actual:X8} vs {expected:X8}");
            }
            ownedDevice.DeviceRemovedReason.CheckError();
            Console.WriteLine($"PASS native D3D11 {desc.Description}: feature_level={featureLevel}, elapsed={stopwatch.Elapsed.TotalSeconds:F2}s, verified_dispatches={dispatches}, readback_values={indices.Length}");
        }
        finally
        {
            ownedContext.Unmap(readback, 0);
        }
    }

    private static Blob CompileShader()
    {
        const string source = """
            RWStructuredBuffer<uint> data : register(u0);
            [numthreads(256, 1, 1)]
            void main(uint3 id : SV_DispatchThreadID)
            {
                uint x = id.x * 747796405u + 2891336453u;
                [loop]
                for (uint i = 0; i < 256; i++)
                {
                    x ^= x >> 16;
                    x *= 2246822519u;
                    x ^= x >> 13;
                    x *= 3266489917u;
                    x ^= x >> 16;
                }
                data[id.x] = x;
            }
            """;

        return Compiler.Compile(
            source,
            "main",
            "GpuStressDx.hlsl",
            Array.Empty<ShaderMacro>(),
            null!,
            "cs_5_0",
            ShaderFlags.OptimizationLevel3,
            EffectFlags.None);
    }

    private static string? GetArg(string[] args, string name)
    {
        int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static double ToGiB(nuint bytes) => (double)bytes / 1024 / 1024 / 1024;

    [DllImport("d3d12.dll")]
    private static extern int D3D12CreateDevice(
        IntPtr adapter,
        int minimumFeatureLevel,
        ref Guid riid,
        out IntPtr device);
}\
