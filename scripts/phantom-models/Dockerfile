# phantom-models — busybox-based image whose /models holds the bundled
# weights/configs. The positronic-control pod's `load-models` initContainer
# uses this image's `cp` to copy /models to a shared emptyDir; the main
# container then mounts that emptyDir at /root/models.
#
# Why busybox and not FROM scratch:
#   The original design used a Kubernetes image: volume source (KEP-4639)
#   with a FROM-scratch image. k0s 1.35.3's containerd has only partial
#   support for that — kubelet pulls the image but containerd can't turn
#   the pulled layers into a mountable rootfs (fails with `mkdir ""` when
#   generating the OCI spec). The fallback path documented in
#   docs/plans/2026-04-24-positronic-k0s-migration.md §3.6a is an
#   initContainer + emptyDir copy, which requires this image to have a
#   shell + cp. busybox adds ~5 MB on top of the ~1+ GB of model weights.
#
# The build context is whatever directory contains the models to bundle
# (typically /root/phantom-models-merged on mk09, or a temp dir assembled
# by build.py from a manifest). Everything in the context lands at /models
# inside the image.
FROM busybox:1.36.1
COPY . /models
