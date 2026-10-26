/* SPDX-License-Identifier: MIT
 * Versioned offscreen Vulkan workloads, not a conformance or peak-FLOPS test.
 * All explicit allocations <=64 MiB. CPU oracle is outside timed regions.
 * Build/self-test never requires GPU initialization. Actual mode is opt-in.
 */
#define _POSIX_C_SOURCE 200809L
#include "shaders.h"
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>
#ifndef GPU_SOURCE_SHA256
#define GPU_SOURCE_SHA256 "unbuilt"
#endif
#define W 1920u
#define H 1080u
#define T 1024u
#define MEMORY_LIMIT (64ull * 1024 * 1024)
static uint64_t live_bytes, peak_bytes, deadline;
static bool initialized;
static void die(const char *reason, int line) {
  fprintf(stderr, "failure at %d: %s\n", line, reason);
  exit(2);
}
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x))                                                                  \
      die(#x, __LINE__);                                                       \
  } while (0)
#define VK(x)                                                                  \
  do {                                                                         \
    VkResult r_ = (x);                                                         \
    if (r_ != VK_SUCCESS) {                                                    \
      fprintf(stderr, "Vulkan result %d\n", r_);                               \
      die(#x, __LINE__);                                                       \
    }                                                                          \
  } while (0)
static void unsupported(void) {
  // Typed capability absence; no driver text is copied to the report.
  exit(3);
}
static uint64_t clock_ns(clockid_t clock) {
  struct timespec t;
  CHECK(!clock_gettime(clock, &t));
  return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static uint64_t now(void) { return clock_ns(CLOCK_MONOTONIC); }
static uint64_t budget(void) {
  uint64_t n = now();
  CHECK(n < deadline);
  uint64_t b = deadline - n;
  return b < 5000000000ull ? b : 5000000000ull;
}
static uint64_t mask(unsigned n) {
  CHECK(n > 0 && n <= 64);
  return n == 64 ? UINT64_MAX : (1ull << n) - 1;
}
static uint64_t delta(uint64_t a, uint64_t b, unsigned n) {
  return (b - a) & mask(n);
}
static uint32_t oracle(uint32_t i, uint32_t seed) {
  uint32_t v = i ^ seed;
  for (unsigned j = 0; j < 32; j++) {
    v = v * 1664525u + 1013904223u;
    v ^= (v >> 13) | (v << 19);
  }
  return v;
}
struct buffer {
  VkBuffer b;
  VkDeviceMemory m;
  void *map;
  uint64_t size;
};
struct image {
  VkImage image;
  VkDeviceMemory memory;
  VkImageView view;
  uint64_t size;
};
struct context {
  VkInstance instance;
  VkPhysicalDevice physical;
  VkDevice device;
  VkQueue queue;
  unsigned family, bits;
  float period;
  VkCommandPool pool;
  VkCommandBuffer cmd;
  VkFence fence;
  VkQueryPool query;
  VkPhysicalDeviceProperties props;
  VkPhysicalDeviceDriverProperties driver;
};
static unsigned memory_type(struct context *c, uint32_t bits,
                            VkMemoryPropertyFlags flags) {
  VkPhysicalDeviceMemoryProperties p;
  vkGetPhysicalDeviceMemoryProperties(c->physical, &p);
  for (unsigned i = 0; i < p.memoryTypeCount; i++)
    if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & flags) == flags)
      return i;
  unsupported();
  return 0;
}
static void charge(uint64_t n) {
  CHECK(n <= MEMORY_LIMIT - live_bytes);
  live_bytes += n;
  if (live_bytes > peak_bytes)
    peak_bytes = live_bytes;
}
static struct buffer buffer_new(struct context *c, uint64_t bytes) {
  struct buffer b = {0};
  VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                           .size = bytes,
                           .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                    VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                                    VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                           .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
  VK(vkCreateBuffer(c->device, &bi, NULL, &b.b));
  VkMemoryRequirements r;
  vkGetBufferMemoryRequirements(c->device, b.b, &r);
  b.size = r.size;
  charge(r.size);
  VkMemoryAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = r.size,
      .memoryTypeIndex = memory_type(c, r.memoryTypeBits,
                                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
  VK(vkAllocateMemory(c->device, &ai, NULL, &b.m));
  VK(vkBindBufferMemory(c->device, b.b, b.m, 0));
  VK(vkMapMemory(c->device, b.m, 0, r.size, 0, &b.map));
  memset(b.map, 0xa5, (size_t)bytes);
  return b;
}
static void buffer_free(struct context *c, struct buffer *b) {
  vkUnmapMemory(c->device, b->m);
  vkDestroyBuffer(c->device, b->b, NULL);
  vkFreeMemory(c->device, b->m, NULL);
  CHECK(live_bytes >= b->size);
  live_bytes -= b->size;
  memset(b, 0, sizeof *b);
}
static struct image image_new(struct context *c, unsigned width,
                              unsigned height, VkImageUsageFlags usage) {
  struct image x = {0};
  VkImageCreateInfo ii = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                          .imageType = VK_IMAGE_TYPE_2D,
                          .format = VK_FORMAT_R8G8B8A8_UNORM,
                          .extent = {width, height, 1},
                          .mipLevels = 1,
                          .arrayLayers = 1,
                          .samples = VK_SAMPLE_COUNT_1_BIT,
                          .tiling = VK_IMAGE_TILING_OPTIMAL,
                          .usage = usage,
                          .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                          .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
  VK(vkCreateImage(c->device, &ii, NULL, &x.image));
  VkMemoryRequirements r;
  vkGetImageMemoryRequirements(c->device, x.image, &r);
  x.size = r.size;
  charge(r.size);
  VkMemoryAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = r.size,
      .memoryTypeIndex = memory_type(c, r.memoryTypeBits,
                                     VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
  VK(vkAllocateMemory(c->device, &ai, NULL, &x.memory));
  VK(vkBindImageMemory(c->device, x.image, x.memory, 0));
  VkImageViewCreateInfo vi = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = x.image,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  VK(vkCreateImageView(c->device, &vi, NULL, &x.view));
  return x;
}
static void image_free(struct context *c, struct image *x) {
  vkDestroyImageView(c->device, x->view, NULL);
  vkDestroyImage(c->device, x->image, NULL);
  vkFreeMemory(c->device, x->memory, NULL);
  live_bytes -= x->size;
}
static bool native_base(const VkPhysicalDeviceProperties *properties) {
  return properties->apiVersion >= VK_API_VERSION_1_2 &&
         properties->vendorID == VK_VENDOR_ID_MESA &&
         properties->deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU &&
         strncmp(properties->deviceName, "Apple ", 6) == 0;
}
static bool native_identity(const VkPhysicalDeviceProperties *properties,
                            const VkPhysicalDeviceDriverProperties *driver) {
  return native_base(properties) &&
         driver->driverID == VK_DRIVER_ID_MESA_HONEYKRISP;
}
static void init(struct context *c) {
  memset(c, 0, sizeof *c);
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                           .pApplicationName = "omarchy-m-test-gpu-suite-1",
                           .apiVersion = VK_API_VERSION_1_2};
  VkInstanceCreateInfo ii = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                             .pApplicationInfo = &app};
  VK(vkCreateInstance(&ii, NULL, &c->instance));
  initialized = true;
  uint32_t n = 0;
  VK(vkEnumeratePhysicalDevices(c->instance, &n, NULL));
  CHECK(n > 0 && n <= 16);
  VkPhysicalDevice devices[16];
  VK(vkEnumeratePhysicalDevices(c->instance, &n, devices));
  unsigned matches = 0;
  for (unsigned i = 0; i < n; i++) {
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(devices[i], &properties);
    // Honeykrisp advertises Khronos' Mesa vendor ID, not Apple's PCI ID.
    // The suite requires Vulkan 1.2 before querying core DriverProperties.
    if (!native_base(&properties))
      continue;
    VkPhysicalDeviceDriverProperties driver = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
    VkPhysicalDeviceProperties2 properties2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &driver};
    vkGetPhysicalDeviceProperties2(devices[i], &properties2);
    if (!native_identity(&properties2.properties, &driver))
      continue;
    c->physical = devices[i];
    c->props = properties2.properties;
    c->driver = driver;
    matches++;
  }
  CHECK(matches == 1);
  uint32_t count = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(c->physical, &count, NULL);
  CHECK(count && count <= 64);
  VkQueueFamilyProperties queues[64];
  vkGetPhysicalDeviceQueueFamilyProperties(c->physical, &count, queues);
  c->family = UINT32_MAX;
  for (unsigned i = 0; i < count; i++)
    if ((queues[i].queueFlags &
         (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) ==
        (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) {
      c->family = i;
      break;
    }
  if (c->family == UINT32_MAX)
    unsupported();
  c->bits = queues[c->family].timestampValidBits;
  CHECK(c->bits == 0 || (c->bits >= 36 && c->bits <= 64));
  c->period = c->props.limits.timestampPeriod;
  CHECK(!c->bits || (isfinite(c->period) && c->period > 0));
  float priority = 0.5f;
  VkDeviceQueueCreateInfo qi = {.sType =
                                    VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                .queueFamilyIndex = c->family,
                                .queueCount = 1,
                                .pQueuePriorities = &priority};
  VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                           .queueCreateInfoCount = 1,
                           .pQueueCreateInfos = &qi};
  VK(vkCreateDevice(c->physical, &di, NULL, &c->device));
  vkGetDeviceQueue(c->device, c->family, 0, &c->queue);
  VkCommandPoolCreateInfo pi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
      .queueFamilyIndex = c->family};
  VK(vkCreateCommandPool(c->device, &pi, NULL, &c->pool));
  VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = c->pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1};
  VK(vkAllocateCommandBuffers(c->device, &ai, &c->cmd));
  VkFenceCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VK(vkCreateFence(c->device, &fi, NULL, &c->fence));
  if (c->bits) {
    VkQueryPoolCreateInfo qp = {.sType =
                                    VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                                .queryType = VK_QUERY_TYPE_TIMESTAMP,
                                .queryCount = 2};
    VK(vkCreateQueryPool(c->device, &qp, NULL, &c->query));
  }
  printf("{\"kind\":\"identity\",\"protocol\":1,\"suite\":1,\"device_name\":\"%"
         "s\",\"vendor_id\":%u,\"device_id\":%u,\"device_type\":%u,\"driver_"
         "name\":\"%s\","
         "\"driver_id\":%u,\"api_version\":%u,\"driver_version\":%u,"
         "\"timestamp_bits\":%u,\"timestamp_period_ps\":%" PRIu64
         ",\"source_sha256\":\"%s\"}\n",
         c->props.deviceName, c->props.vendorID, c->props.deviceID,
         c->props.deviceType, c->driver.driverName, c->driver.driverID,
         c->props.apiVersion, c->props.driverVersion, c->bits,
         (uint64_t)(c->period * 1000.0 + 0.5), GPU_SOURCE_SHA256);
  fflush(stdout);
  struct timespec grace = {.tv_nsec = 400000000};
  CHECK(!nanosleep(&grace, NULL));
}
static void finish(struct context *c) {
  if (c->query)
    vkDestroyQueryPool(c->device, c->query, NULL);
  vkDestroyFence(c->device, c->fence, NULL);
  vkDestroyCommandPool(c->device, c->pool, NULL);
  vkDestroyDevice(c->device, NULL);
  vkDestroyInstance(c->instance, NULL);
  CHECK(!live_bytes);
}
static VkShaderModule shader(struct context *c, const uint32_t *code,
                             size_t size) {
  VkShaderModuleCreateInfo si = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = size,
      .pCode = code};
  VkShaderModule result;
  VK(vkCreateShaderModule(c->device, &si, NULL, &result));
  return result;
}
static void begin(struct context *c) {
  VK(vkResetCommandBuffer(c->cmd, 0));
  VkCommandBufferBeginInfo bi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  VK(vkBeginCommandBuffer(c->cmd, &bi));
  if (c->query) {
    vkCmdResetQueryPool(c->cmd, c->query, 0, 2);
    vkCmdWriteTimestamp(c->cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c->query, 0);
  }
}
static void timestamp_end(struct context *c) {
  if (c->query)
    vkCmdWriteTimestamp(c->cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, c->query,
                        1);
}
struct timings {
  uint64_t record, submit_wait, thread_cpu, gpu, lifetime;
  unsigned queries, submissions;
};
static void submit(struct context *c, struct timings *t) {
  uint64_t closing = now();
  VK(vkEndCommandBuffer(c->cmd));
  t->record += now() - closing;
  uint64_t start = now();
  VK(vkResetFences(c->device, 1, &c->fence));
  VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                     .commandBufferCount = 1,
                     .pCommandBuffers = &c->cmd};
  VK(vkQueueSubmit(c->queue, 1, &si, c->fence));
  VK(vkWaitForFences(c->device, 1, &c->fence, VK_TRUE, budget()));
  t->submit_wait += now() - start;
  t->submissions++;
  if (c->query) {
    uint64_t q[4] = {0};
    VK(vkGetQueryPoolResults(
        c->device, c->query, 0, 2, sizeof q, q, 2 * sizeof(uint64_t),
        VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT));
    CHECK(q[1] && q[3]);
    uint64_t ticks = delta(q[0], q[2], c->bits);
    long double ns = (long double)ticks * c->period;
    // A modulo delta is meaningful only if the completion interval cannot
    // contain a whole counter period. The fence bound alone is insufficient
    // on an implementation with a small counter and sub-nanosecond ticks.
    long double counter_period = ldexpl((long double)c->period, c->bits);
    CHECK((long double)(now() - start) < counter_period);
    CHECK(ns >= 0 && ns <= 5000000000.0L);
    t->gpu += (uint64_t)(ns + 0.5L);
    t->queries++;
  }
}
static void barrier_image(struct context *c, VkImage image, VkImageLayout old,
                          VkImageLayout next, VkAccessFlags src,
                          VkAccessFlags dst, VkPipelineStageFlags from,
                          VkPipelineStageFlags to) {
  VkImageMemoryBarrier b = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = src,
      .dstAccessMask = dst,
      .oldLayout = old,
      .newLayout = next,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = image,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  vkCmdPipelineBarrier(c->cmd, from, to, 0, 0, NULL, 0, NULL, 1, &b);
}
static void host_barrier(struct context *c, VkAccessFlags src,
                         VkPipelineStageFlags stage) {
  VkMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                       .srcAccessMask = src,
                       .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vkCmdPipelineBarrier(c->cmd, stage, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &b, 0,
                       NULL, 0, NULL);
}
static unsigned compute(struct context *c, const char *work, struct timings *t,
                        bool negative) {
  bool single = !strcmp(work, "submit-single"),
       batched = !strcmp(work, "submit-batched"),
       lifetime = !strcmp(work, "bo-lifetime");
  unsigned submits = single     ? 128
                     : batched  ? 4
                     : lifetime ? 32
                                : 8,
           dispatches = single || lifetime ? 1
                        : batched          ? 32
                                           : 8;
  uint64_t bytes = single || batched || lifetime ? 1024 : 8 * 1024 * 1024;
  if (bytes > c->props.limits.maxStorageBufferRange)
    unsupported();
  VkDescriptorSetLayoutBinding binding = {
      .binding = 0,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .descriptorCount = 1,
      .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
  VkDescriptorSetLayoutCreateInfo dl = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 1,
      .pBindings = &binding};
  VkDescriptorSetLayout layout;
  VK(vkCreateDescriptorSetLayout(c->device, &dl, NULL, &layout));
  VkPushConstantRange pc = {.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
                            .size = 8};
  VkPipelineLayoutCreateInfo pl = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1,
      .pSetLayouts = &layout,
      .pushConstantRangeCount = 1,
      .pPushConstantRanges = &pc};
  VkPipelineLayout pipeline_layout;
  VK(vkCreatePipelineLayout(c->device, &pl, NULL, &pipeline_layout));
  VkShaderModule sm = shader(c, compute_spv, sizeof compute_spv);
  VkComputePipelineCreateInfo cp = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                .module = sm,
                .pName = "main"},
      .layout = pipeline_layout};
  VkPipeline pipeline;
  VK(vkCreateComputePipelines(c->device, VK_NULL_HANDLE, 1, &cp, NULL,
                              &pipeline));
  VkDescriptorPoolSize ps = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                             .descriptorCount = 1};
  VkDescriptorPoolCreateInfo dp = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .maxSets = 1,
      .poolSizeCount = 1,
      .pPoolSizes = &ps};
  VkDescriptorPool pool;
  VK(vkCreateDescriptorPool(c->device, &dp, NULL, &pool));
  VkDescriptorSetAllocateInfo da = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool = pool,
      .descriptorSetCount = 1,
      .pSetLayouts = &layout};
  VkDescriptorSet set;
  VK(vkAllocateDescriptorSets(c->device, &da, &set));
  struct buffer b = {0};
  if (!lifetime)
    b = buffer_new(c, bytes);
  unsigned wrong = 0, sequence = 0;
  for (unsigned run = 0; run < submits; run++) {
    uint64_t lifetime_start = now(),
             cpu_start = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    if (lifetime)
      b = buffer_new(c, bytes);
    VkDescriptorBufferInfo info = {.buffer = b.b, .range = bytes};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &info};
    vkUpdateDescriptorSets(c->device, 1, &write, 0, NULL);
    uint64_t record_start = now();
    begin(c);
    vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(c->cmd, VK_PIPELINE_BIND_POINT_COMPUTE,
                            pipeline_layout, 0, 1, &set, 0, NULL);
    uint32_t seed = 0;
    for (unsigned j = 0; j < dispatches; j++) {
      seed = 0x51c0ffeeu + sequence++;
      uint32_t push[2] = {seed, (uint32_t)(bytes / 4)};
      vkCmdPushConstants(c->cmd, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT,
                         0, 8, push);
      vkCmdDispatch(c->cmd, ((uint32_t)(bytes / 4) + 63) / 64, 1, 1);
      VkMemoryBarrier b2 = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                            .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
                            .dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT};
      vkCmdPipelineBarrier(c->cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                           VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &b2, 0,
                           NULL, 0, NULL);
    }
    host_barrier(c, VK_ACCESS_SHADER_WRITE_BIT,
                 VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
    timestamp_end(c);
    t->record += now() - record_start;
    submit(c, t);
    t->thread_cpu += clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu_start;
    uint64_t before_oracle = now();
    uint32_t *values = b.map;
    for (unsigned i = 0; i < bytes / 4; i++) {
      uint32_t expected = oracle(i, seed);
      if (negative && i == 0)
        expected ^= 1;
      if (values[i] != expected)
        wrong++;
    }
    uint64_t oracle_ns = now() - before_oracle;
    if (lifetime) {
      buffer_free(c, &b);
      t->lifetime += now() - lifetime_start - oracle_ns;
    }
    if (wrong)
      break;
  }
  if (!lifetime)
    buffer_free(c, &b);
  vkDestroyDescriptorPool(c->device, pool, NULL);
  vkDestroyPipeline(c->device, pipeline, NULL);
  vkDestroyShaderModule(c->device, sm, NULL);
  vkDestroyPipelineLayout(c->device, pipeline_layout, NULL);
  vkDestroyDescriptorSetLayout(c->device, layout, NULL);
  return wrong;
}
static void texel(unsigned x, unsigned y, uint8_t *out) {
  out[0] = x & 255;
  out[1] = y & 255;
  out[2] = (x ^ y) & 255;
  out[3] = 255;
}
static unsigned render(struct context *c, bool textured, struct timings *t,
                       bool negative) {
  struct image target = image_new(c, W, H,
                                  VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                      VK_IMAGE_USAGE_TRANSFER_SRC_BIT),
               texture = {0};
  struct buffer readback = buffer_new(c, (uint64_t)W * H * 4);
  VkSampler sampler = VK_NULL_HANDLE;
  VkDescriptorSetLayout descriptor_layout = VK_NULL_HANDLE;
  VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
  VkDescriptorSet set = VK_NULL_HANDLE;
  if (textured) {
    texture = image_new(
        c, T, T, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    struct buffer upload = buffer_new(c, (uint64_t)T * T * 4);
    uint8_t *data = upload.map;
    for (unsigned y = 0; y < T; y++)
      for (unsigned x = 0; x < T; x++)
        texel(x, y, data + ((uint64_t)y * T + x) * 4);
    begin(c);
    barrier_image(
        c, texture.image, VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy copy = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {T, T, 1}};
    vkCmdCopyBufferToImage(c->cmd, upload.b, texture.image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    barrier_image(c, texture.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                  VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
                  VK_PIPELINE_STAGE_TRANSFER_BIT,
                  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    timestamp_end(c);
    struct timings ignored = {0};
    submit(c, &ignored);
    buffer_free(c, &upload);
    VkSamplerCreateInfo si = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                              .magFilter = VK_FILTER_NEAREST,
                              .minFilter = VK_FILTER_NEAREST,
                              .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
                              .addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT,
                              .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
                              .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT,
                              .maxLod = 0};
    VK(vkCreateSampler(c->device, &si, NULL, &sampler));
    VkDescriptorSetLayoutBinding binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo dl = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &binding};
    VK(vkCreateDescriptorSetLayout(c->device, &dl, NULL, &descriptor_layout));
    VkDescriptorPoolSize ps = {.type =
                                   VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                               .descriptorCount = 1};
    VkDescriptorPoolCreateInfo dp = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &ps};
    VK(vkCreateDescriptorPool(c->device, &dp, NULL, &descriptor_pool));
    VkDescriptorSetAllocateInfo da = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &descriptor_layout};
    VK(vkAllocateDescriptorSets(c->device, &da, &set));
    VkDescriptorImageInfo info = {.sampler = sampler,
                                  .imageView = texture.view,
                                  .imageLayout =
                                      VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &info};
    vkUpdateDescriptorSets(c->device, 1, &write, 0, NULL);
  }
  VkAttachmentDescription attachment = {
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
      .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
      .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkAttachmentReference reference = {0,
                                     VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription subpass = {.pipelineBindPoint =
                                      VK_PIPELINE_BIND_POINT_GRAPHICS,
                                  .colorAttachmentCount = 1,
                                  .pColorAttachments = &reference};
  VkRenderPassCreateInfo rp = {.sType =
                                   VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                               .attachmentCount = 1,
                               .pAttachments = &attachment,
                               .subpassCount = 1,
                               .pSubpasses = &subpass};
  VkRenderPass pass;
  VK(vkCreateRenderPass(c->device, &rp, NULL, &pass));
  VkFramebufferCreateInfo fb = {.sType =
                                    VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                .renderPass = pass,
                                .attachmentCount = 1,
                                .pAttachments = &target.view,
                                .width = W,
                                .height = H,
                                .layers = 1};
  VkFramebuffer framebuffer;
  VK(vkCreateFramebuffer(c->device, &fb, NULL, &framebuffer));
  VkPushConstantRange fragment_push = {
      .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT, .size = 4};
  VkPipelineLayoutCreateInfo pl = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = textured ? 1u : 0u,
      .pSetLayouts = textured ? &descriptor_layout : NULL,
      .pushConstantRangeCount = 1,
      .pPushConstantRanges = &fragment_push};
  VkPipelineLayout layout;
  VK(vkCreatePipelineLayout(c->device, &pl, NULL, &layout));
  VkShaderModule vs = shader(c, fullscreen_spv, sizeof fullscreen_spv),
                 fs = shader(c, textured ? texture_spv : raster_spv,
                             textured ? sizeof texture_spv : sizeof raster_spv);
  VkPipelineShaderStageCreateInfo stages[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = vs,
       .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = fs,
       .pName = "main"}};
  VkPipelineVertexInputStateCreateInfo vertex = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
  VkPipelineInputAssemblyStateCreateInfo assembly = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
  VkViewport viewport = {0, 0, W, H, 0, 1};
  VkRect2D scissor = {{0, 0}, {W, H}};
  VkPipelineViewportStateCreateInfo vp = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .pViewports = &viewport,
      .scissorCount = 1,
      .pScissors = &scissor};
  VkPipelineRasterizationStateCreateInfo raster = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL,
      .cullMode = VK_CULL_MODE_NONE,
      .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
      .lineWidth = 1};
  VkPipelineMultisampleStateCreateInfo ms = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
  // Every draw contributes to the final image: opaque overdraw would permit
  // hidden-surface elimination to discard the intended fill/texture work.
  VkPipelineColorBlendAttachmentState blend_attachment = {
      .blendEnable = VK_TRUE,
      .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
      .dstColorBlendFactor = VK_BLEND_FACTOR_ONE,
      .colorBlendOp = VK_BLEND_OP_ADD,
      .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
      .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
      .alphaBlendOp = VK_BLEND_OP_ADD,
      .colorWriteMask = 15};
  VkPipelineColorBlendStateCreateInfo blend = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &blend_attachment};
  VkGraphicsPipelineCreateInfo gi = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2,
      .pStages = stages,
      .pVertexInputState = &vertex,
      .pInputAssemblyState = &assembly,
      .pViewportState = &vp,
      .pRasterizationState = &raster,
      .pMultisampleState = &ms,
      .pColorBlendState = &blend,
      .layout = layout,
      .renderPass = pass};
  VkPipeline pipeline;
  VK(vkCreateGraphicsPipelines(c->device, VK_NULL_HANDLE, 1, &gi, NULL,
                               &pipeline));
  unsigned wrong = 0;
  for (unsigned iteration = 0; iteration < 16; iteration++) {
    uint64_t cpu = clock_ns(CLOCK_THREAD_CPUTIME_ID), start = now();
    begin(c);
    barrier_image(c, target.image,
                  iteration ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                            : VK_IMAGE_LAYOUT_UNDEFINED,
                  VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                  iteration ? VK_ACCESS_TRANSFER_READ_BIT : 0,
                  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                  iteration ? VK_PIPELINE_STAGE_TRANSFER_BIT
                            : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
    VkClearValue clear = {.color = {{0, 0, 0, 0}}};
    VkRenderPassBeginInfo bi = {.sType =
                                    VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                .renderPass = pass,
                                .framebuffer = framebuffer,
                                .renderArea = {{0, 0}, {W, H}},
                                .clearValueCount = 1,
                                .pClearValues = &clear};
    vkCmdBeginRenderPass(c->cmd, &bi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    if (textured)
      vkCmdBindDescriptorSets(c->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout,
                              0, 1, &set, 0, NULL);
    uint32_t frame_seed = 0x21u + iteration;
    vkCmdPushConstants(c->cmd, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 4,
                       &frame_seed);
    for (unsigned draw = 0; draw < (textured ? 4u : 16u); draw++)
      vkCmdDraw(c->cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(c->cmd);
    timestamp_end(c);
    barrier_image(c, target.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                  VK_ACCESS_TRANSFER_READ_BIT,
                  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                  VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy copy = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(c->cmd, target.image,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.b, 1,
                           &copy);
    host_barrier(c, VK_ACCESS_TRANSFER_WRITE_BIT,
                 VK_PIPELINE_STAGE_TRANSFER_BIT);
    t->record += now() - start;
    submit(c, t);
    t->thread_cpu += clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu;
    uint8_t *data = readback.map;
    for (unsigned y = 0; y < H; y++)
      for (unsigned x = 0; x < W; x++) {
        uint8_t wanted[4];
        if (!textured) {
          texel(x + frame_seed, y + frame_seed * 3, wanted);
          for (unsigned channel = 0; channel < 4; channel++)
            wanted[channel] = (wanted[channel] & 15) * 16;
        } else {
          unsigned sum[4] = {0};
          for (unsigned k = 0; k < 4; k++) {
            uint8_t p[4];
            texel((x * 13 + frame_seed * 7 + (k & 1 ? 37 : 0)) & 1023,
                  (y * 17 + frame_seed * 11 + (k & 2 ? 53 : 0)) & 1023, p);
            for (unsigned channel = 0; channel < 4; channel++)
              sum[channel] += p[channel];
          }
          for (unsigned channel = 0; channel < 4; channel++)
            wanted[channel] = (sum[channel] >> 4) * 4;
        }
        if (negative && x == 0 && y == 0)
          wanted[0] ^= 128;
        for (unsigned channel = 0; channel < 4; channel++) {
          int diff =
              (int)data[((uint64_t)y * W + x) * 4 + channel] - wanted[channel];
          if (diff > 1 || diff < -1)
            wrong++;
        }
      }
    if (wrong)
      break;
  }
  vkDestroyPipeline(c->device, pipeline, NULL);
  vkDestroyShaderModule(c->device, vs, NULL);
  vkDestroyShaderModule(c->device, fs, NULL);
  vkDestroyPipelineLayout(c->device, layout, NULL);
  vkDestroyFramebuffer(c->device, framebuffer, NULL);
  vkDestroyRenderPass(c->device, pass, NULL);
  if (textured) {
    vkDestroyDescriptorPool(c->device, descriptor_pool, NULL);
    vkDestroyDescriptorSetLayout(c->device, descriptor_layout, NULL);
    vkDestroySampler(c->device, sampler, NULL);
    image_free(c, &texture);
  }
  buffer_free(c, &readback);
  image_free(c, &target);
  return wrong;
}
static unsigned device_copy(struct context *c, struct timings *t,
                            bool negative) {
  const uint64_t bytes = 32ull * 1024 * 1024;
  struct buffer src = buffer_new(c, bytes), dst = buffer_new(c, bytes);
  unsigned wrong = 0;
  for (unsigned iteration = 0; iteration < 32; iteration++) {
    uint32_t seed = 0x93450000u + iteration;
    uint32_t *input = src.map, *output = dst.map;
    for (uint32_t i = 0; i < bytes / 4; i++)
      input[i] = i ^ seed;
    uint64_t cpu = clock_ns(CLOCK_THREAD_CPUTIME_ID), start = now();
    begin(c);
    VkMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                         .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
                         .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT};
    vkCmdPipelineBarrier(c->cmd, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &b, 0, NULL, 0,
                         NULL);
    VkBufferCopy region = {.size = bytes};
    vkCmdCopyBuffer(c->cmd, src.b, dst.b, 1, &region);
    timestamp_end(c);
    host_barrier(c, VK_ACCESS_TRANSFER_WRITE_BIT,
                 VK_PIPELINE_STAGE_TRANSFER_BIT);
    t->record += now() - start;
    submit(c, t);
    t->thread_cpu += clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu;
    for (uint32_t i = 0; i < bytes / 4; i++) {
      uint32_t expected = i ^ seed;
      if (negative && i == 0)
        expected ^= 1;
      if (output[i] != expected)
        wrong++;
    }
    if (wrong)
      break;
  }
  buffer_free(c, &dst);
  buffer_free(c, &src);
  return wrong;
}
static void self_test(void) {
  CHECK(!initialized);
  VkPhysicalDeviceProperties properties = {
      .apiVersion = VK_API_VERSION_1_2,
      .vendorID = VK_VENDOR_ID_MESA,
      .deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
      .deviceName = "Apple M1 (G13G B1)"};
  VkPhysicalDeviceDriverProperties driver = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
      .driverID = VK_DRIVER_ID_MESA_HONEYKRISP};
  CHECK(native_identity(&properties, &driver));
  properties.vendorID = 0x106b;
  CHECK(!native_identity(&properties, &driver));
  properties.vendorID = VK_VENDOR_ID_MESA;
  driver.driverID = VK_DRIVER_ID_MOLTENVK;
  CHECK(!native_identity(&properties, &driver));
  driver.driverID = VK_DRIVER_ID_MESA_LLVMPIPE;
  CHECK(!native_identity(&properties, &driver));
  driver.driverID = VK_DRIVER_ID_MESA_HONEYKRISP;
  properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_CPU;
  CHECK(!native_identity(&properties, &driver));
  properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
  CHECK(!native_identity(&properties, &driver));
  properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU;
  CHECK(!native_identity(&properties, &driver));
  properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;
  properties.apiVersion = VK_API_VERSION_1_1;
  CHECK(!native_identity(&properties, &driver));
  properties.apiVersion = VK_API_VERSION_1_2;
  strcpy(properties.deviceName, "llvmpipe");
  CHECK(!native_identity(&properties, &driver));
  CHECK(delta(65530, 3, 16) == 9);
  CHECK(delta(UINT64_MAX - 2, 2, 64) == 5);
  CHECK(mask(64) == UINT64_MAX);
  CHECK(oracle(0, 1) != oracle(1, 1));
  uint8_t p[4];
  texel(257, 258, p);
  CHECK(p[0] == 1 && p[1] == 2 && p[2] == 3 && p[3] == 255);
  printf("{\"host_self_test\":true,\"gpu_initialized\":false}\n");
}
int main(int argc, char **argv) {
  const char *work = NULL;
  bool negative = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--host-self-test")) {
      self_test();
      return 0;
    }
    if (!strcmp(argv[i], "--negative-control")) {
      negative = true;
      continue;
    }
    CHECK(!strcmp(argv[i], "--workload") && i + 1 < argc);
    work = argv[++i];
  }
  CHECK(work);
  CHECK(!strcmp(work, "raster") || !strcmp(work, "texture") ||
        !strcmp(work, "compute") || !strcmp(work, "submit-single") ||
        !strcmp(work, "submit-batched") || !strcmp(work, "bo-lifetime") ||
        !strcmp(work, "copy"));
  deadline = now() + 40000000000ull;
  struct context c;
  init(&c);
  struct timings t = {0};
  bool graphics = !strcmp(work, "raster") || !strcmp(work, "texture");
  unsigned wrong = graphics ? render(&c, !strcmp(work, "texture"), &t, negative)
                   : !strcmp(work, "copy") ? device_copy(&c, &t, negative)
                                           : compute(&c, work, &t, negative);
  if (negative)
    CHECK(wrong == 1);
  printf("{\"kind\":\"result\",\"protocol\":1,\"suite\":1,\"workload\":\"%s\","
         "\"status\":\"%s\",\"negative_control\":%s,\"mismatches\":%u,"
         "\"width\":%u,\"height\":%u,\"operations\":%u,\"record_ns\":%" PRIu64
         ",\"submit_wait_ns\":%" PRIu64 ",\"thread_cpu_ns\":%" PRIu64
         ",\"gpu_timestamp_ns\":%" PRIu64
         ",\"gpu_timestamp_queries\":%u,\"gpu_timestamp_status\":\"%s\",\"bo_"
         "lifetime_ns\":%" PRIu64 ",\"owned_bytes_peak\":%" PRIu64 "}\n",
         work, wrong ? "fail" : "pass", negative ? "true" : "false", wrong,
         graphics ? W : 0, graphics ? H : 0,
         t.submissions * (!strcmp(work, "raster")           ? 16
                          : !strcmp(work, "texture")        ? 4
                          : !strcmp(work, "compute")        ? 8
                          : !strcmp(work, "submit-batched") ? 32
                                                            : 1),
         t.record, t.submit_wait, t.thread_cpu, t.gpu, t.queries,
         c.bits ? "supported" : "unsupported", t.lifetime, peak_bytes);
  finish(&c);
  return wrong ? 1 : 0;
}
