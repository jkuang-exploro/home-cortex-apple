#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct HCDetector HCDetector;
typedef struct {
    int32_t tag_id;
    double margin;
    double corners[8];
    double camera_from_tag[16];
    double alternative_camera_from_tag[16];
    int32_t has_alternative;
} HCDetection;

HCDetector *hc_detector_create(void);
void hc_detector_destroy(HCDetector *detector);
// Raw grayscale pixels and intrinsics in the SAME unrotated image coordinates.
int32_t hc_detect(HCDetector *detector, const uint8_t *pixels, int32_t width,
    int32_t height, int32_t stride, double fx, double fy, double cx, double cy,
    const double *tag_sizes, size_t size_count, HCDetection *output, int32_t capacity);
