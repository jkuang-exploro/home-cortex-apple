#include "HCDetector.h"
#include "apriltag.h"
#include "apriltag_pose.h"
#include "tag36h11.h"
#include <stdlib.h>
#include <math.h>
#include <string.h>

struct HCDetector { apriltag_detector_t *detector; apriltag_family_t *family; };
HCDetector *hc_detector_create(void) {
    HCDetector *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->family = tag36h11_create();
    d->detector = apriltag_detector_create();
    apriltag_detector_add_family_bits(d->detector, d->family, 1);
    d->detector->nthreads = 2;
    d->detector->quad_decimate = 1.0;
    d->detector->refine_edges = true;
    return d;
}
void hc_detector_destroy(HCDetector *d) {
    if (!d) return;
    apriltag_detector_destroy(d->detector);
    tag36h11_destroy(d->family);
    free(d);
}
static int copy_pose(apriltag_pose_t *p, double *out) {
    if (!p->R || !p->t || MATD_EL(p->t, 2, 0) <= 0) return 0;
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) out[r*4+c] = MATD_EL(p->R, r, c);
        out[r*4+3] = MATD_EL(p->t, r, 0);
    }
    out[12] = out[13] = out[14] = 0; out[15] = 1;
    for (int i = 0; i < 16; i++) if (!isfinite(out[i])) return 0;
    return 1;
}
static void free_pose(apriltag_pose_t *p) { matd_destroy(p->R); matd_destroy(p->t); }
int32_t hc_detect(HCDetector *d, const uint8_t *pixels, int32_t width,
    int32_t height, int32_t stride, double fx, double fy, double cx, double cy,
    const double *sizes, size_t size_count, HCDetection *output, int32_t capacity) {
    if (!d || !pixels || width <= 0 || height <= 0 || stride < width ||
        !isfinite(fx) || !isfinite(fy) || !isfinite(cx) || !isfinite(cy) ||
        fx <= 0 || fy <= 0 || !sizes || !output || capacity <= 0) return 0;
    image_u8_t image = { .width=width, .height=height, .stride=stride, .buf=(uint8_t *)pixels };
    zarray_t *detections = apriltag_detector_detect(d->detector, &image);
    int32_t count = 0;
    for (int i=0; i<zarray_size(detections) && count<capacity; i++) {
        apriltag_detection_t *det; zarray_get(detections, i, &det);
        if (det->id < 0 || (size_t)det->id >= size_count || !isfinite(sizes[det->id]) || sizes[det->id] <= 0 ||
            det->hamming != 0 || det->decision_margin < 20) continue;
        apriltag_detection_info_t info = { .det=det, .tagsize=sizes[det->id], .fx=fx, .fy=fy, .cx=cx, .cy=cy };
        apriltag_pose_t a = {0}, b = {0}; double ea, eb;
        estimate_tag_pose_orthogonal_iteration(&info, &ea, &a, &eb, &b, 50);
        HCDetection result = { .tag_id=det->id, .margin=det->decision_margin };
        apriltag_pose_t *best = ea <= eb ? &a : &b;
        apriltag_pose_t *other = ea <= eb ? &b : &a;
        if (copy_pose(best, result.camera_from_tag)) {
            result.has_alternative = copy_pose(other, result.alternative_camera_from_tag);
            for (int j=0; j<4; j++) { result.corners[2*j]=det->p[j][0]; result.corners[2*j+1]=det->p[j][1]; }
            output[count++] = result;
        }
        free_pose(&a); free_pose(&b);
    }
    apriltag_detections_destroy(detections);
    return count;
}
