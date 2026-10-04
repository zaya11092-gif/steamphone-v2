//
// SteamPhone GPU Bridge (SPGB)
// Copyright (C) 2026 steamphone-v2 contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

struct SPGBProbeResult {
    let apiVersion: String
    let deviceName: String
    let driverVersion: String
    let queueFamilyCount: UInt32
    let memoryTypeCount: UInt32
    let graphicsQueue: Bool
}

#if canImport(Vulkan)
import Vulkan

/// On-device G0 probe: does Vulkan work on this iPhone through MoltenVK?
/// Establishes the base of the 3D track (gpu-rd/3d-plan.md WP1): instance,
/// physical device enumeration, logical device + queue, and an idle wait —
/// the facts the gfxstream host port needs before anything else.
///
/// Note on the C API surface: modern Vulkan headers expose version helpers
/// as static inline functions (VK_MAKE_API_VERSION, VK_VERSION_MAJOR…),
/// which import into Swift; function-like macros do not, so we avoid them.
enum SPGBVulkanProbe {
    static var isAvailable: Bool { true }

    static func run() throws -> SPGBProbeResult {
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.pApplicationName = "SteamPhone GPU Bridge"
        appInfo.applicationVersion = VK_MAKE_API_VERSION(0, 0, 2, 0)
        appInfo.pEngineName = "SPGB"
        appInfo.engineVersion = VK_MAKE_API_VERSION(0, 0, 2, 0)
        appInfo.apiVersion = VK_MAKE_API_VERSION(0, 1, 1, 0)

        var createInfo = VkInstanceCreateInfo()
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        createInfo.pApplicationInfo = withUnsafePointer(to: appInfo) { $0 }

        var instance: VkInstance? = nil
        try check(vkCreateInstance(&createInfo, nil, &instance), "vkCreateInstance")
        guard let instance else { throw SPGBError.pipelineFailure("no VkInstance") }
        defer { vkDestroyInstance(instance, nil) }

        var deviceCount: UInt32 = 0
        try check(vkEnumeratePhysicalDevices(instance, &deviceCount, nil), "vkEnumeratePhysicalDevices(count)")
        guard deviceCount > 0 else { throw SPGBError.pipelineFailure("no physical devices") }

        var physicalDevices = [VkPhysicalDevice?](repeating: nil, count: Int(deviceCount))
        try check(vkEnumeratePhysicalDevices(instance, &deviceCount, &physicalDevices), "vkEnumeratePhysicalDevices")
        guard let physical = physicalDevices.compactMap({ $0 }).first else {
            throw SPGBError.pipelineFailure("physical device handle nil")
        }

        var properties = VkPhysicalDeviceProperties()
        vkGetPhysicalDeviceProperties(physical, &properties)

        var memoryProperties = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physical, &memoryProperties)

        var queueFamilyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &queueFamilyCount, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(),
                                                 count: max(Int(queueFamilyCount), 1))
        if queueFamilyCount > 0 {
            vkGetPhysicalDeviceQueueFamilyProperties(physical, &queueFamilyCount, &families)
        }
        let graphicsFamily = families.prefix(Int(max(queueFamilyCount, 1))).firstIndex {
            ($0.queueFlags & UInt32(VK_QUEUE_GRAPHICS_BIT.rawValue)) != 0
        }
        let queueFamilyIndex = UInt32(graphicsFamily ?? 0)

        var queuePriority = Float(1.0)
        var queueCreateInfo = VkDeviceQueueCreateInfo()
        queueCreateInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        queueCreateInfo.queueFamilyIndex = queueFamilyIndex
        queueCreateInfo.queueCount = 1
        queueCreateInfo.pQueuePriorities = withUnsafePointer(to: queuePriority) { $0 }

        var deviceCreateInfo = VkDeviceCreateInfo()
        deviceCreateInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        deviceCreateInfo.queueCreateInfoCount = 1
        deviceCreateInfo.pQueueCreateInfos = withUnsafePointer(to: queueCreateInfo) { $0 }

        // Zero-extension creation first; retry with VK_KHR_portability_subset
        // (MoltenVK exposes it and some layers want it enabled).
        var device: VkDevice? = nil
        var result = vkCreateDevice(physical, &deviceCreateInfo, nil, &device)
        if result != VK_SUCCESS {
            result = createPortabilityDevice(physical, queueCreateInfo: queueCreateInfo,
                                             createInfo: &deviceCreateInfo, device: &device)
        }
        try check(result, "vkCreateDevice")
        guard let device else { throw SPGBError.pipelineFailure("no VkDevice") }
        defer { vkDestroyDevice(device, nil) }

        var queue: VkQueue? = nil
        vkGetDeviceQueue(device, queueFamilyIndex, 0, &queue)
        guard queue != nil else { throw SPGBError.pipelineFailure("no VkQueue") }
        vkDeviceWaitIdle(device)

        return SPGBProbeResult(
            apiVersion: versionString(properties.apiVersion),
            deviceName: String(cString: properties.deviceName),
            driverVersion: String(format: "0x%08x", properties.driverVersion),
            queueFamilyCount: queueFamilyCount,
            memoryTypeCount: memoryProperties.memoryTypeCount,
            graphicsQueue: graphicsFamily != nil)
    }

    /// vkCreateDevice with the portability extension enabled; all C-string
    /// pointers stay alive inside the innermost scope where the call happens.
    private static func createPortabilityDevice(_ physical: VkPhysicalDevice,
                                                queueCreateInfo: VkDeviceQueueCreateInfo,
                                                createInfo: inout VkDeviceCreateInfo,
                                                device: UnsafeMutablePointer<VkDevice?>) -> VkResult {
        let name = "VK_KHR_portability_subset"
        var nameC = Array(name.utf8CString) // includes NUL
        return nameC.withUnsafeMutableBufferPointer { nameBuf -> VkResult in
            var extensions: [UnsafePointer<CChar>?] = [UnsafePointer(nameBuf.baseAddress!)]
            return extensions.withUnsafeMutableBufferPointer { extBuf -> VkResult in
                createInfo.enabledExtensionCount = 1
                createInfo.ppEnabledExtensionNames = extBuf.baseAddress
                return vkCreateDevice(physical, &createInfo, nil, device)
            }
        }
    }

    private static func versionString(_ version: UInt32) -> String {
        let major = VK_VERSION_MAJOR(version)
        let minor = VK_VERSION_MINOR(version)
        let patch = VK_VERSION_PATCH(version)
        return "\(major).\(minor).\(patch)"
    }

    private static func check(_ result: VkResult, _ what: String) throws {
        guard result == VK_SUCCESS else {
            throw SPGBError.pipelineFailure("\(what) -> VkResult(\(result.rawValue))")
        }
    }
}

#else

/// Compile-time fallback when MoltenVK is not linked (default builds).
enum SPGBVulkanProbe {
    static var isAvailable: Bool { false }
    static func run() throws -> SPGBProbeResult {
        throw SPGBError.pipelineFailure("Vulkan unavailable: build the MoltenVK profile (gpu-rd/moltenvk/README.md)")
    }
}

#endif
