# okvis2x — restart commands

Run on the robot/node (k0s).

Restart + wait for rollout:

```bash
sudo k0s kubectl -n positronic rollout restart ds/okvis2x && sudo k0s kubectl -n positronic rollout status ds/okvis2x
```

Restart + follow the app logs:

```bash
sudo k0s kubectl -n positronic rollout restart ds/okvis2x; sudo k0s kubectl -n positronic logs -f ds/okvis2x -c okvis2x
```

Hard restart (delete the pod, k8s recreates it):

```bash
sudo k0s kubectl -n positronic delete pod -l app.kubernetes.io/name=okvis2x
```
