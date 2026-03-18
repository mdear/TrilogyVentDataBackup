import sys
from collections import deque
from statistics import median

from PIL import Image


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("Usage: python analyze_shield_reference.py <path-to-image>")
    img = Image.open(sys.argv[1]).convert("RGBA")
    width, height = img.size
    px = img.load()

    base_mask = [[False] * width for _ in range(height)]

    for y in range(height):
        for x in range(width):
            r, g, b, a = px[x, y]
            if a > 0 and r < 70 and g < 70 and b < 70:
                base_mask[y][x] = True

    visited = [[False] * width for _ in range(height)]
    components: list[list[tuple[int, int]]] = []
    neighbors = ((1, 0), (-1, 0), (0, 1), (0, -1))

    for y in range(height):
        for x in range(width):
            if visited[y][x] or not base_mask[y][x]:
                continue

            queue = deque([(x, y)])
            visited[y][x] = True
            component: list[tuple[int, int]] = []

            while queue:
                cx, cy = queue.popleft()
                component.append((cx, cy))
                for dx, dy in neighbors:
                    nx = cx + dx
                    ny = cy + dy
                    if 0 <= nx < width and 0 <= ny < height and not visited[ny][nx] and base_mask[ny][nx]:
                        visited[ny][nx] = True
                        queue.append((nx, ny))

            components.append(component)

    if not components:
        raise SystemExit("no dark components found")

    component = max(components, key=len)
    xs = [x for x, _ in component]
    ys = [y for _, y in component]
    mask = [[False] * width for _ in range(height)]
    for x, y in component:
        mask[y][x] = True

    print(f"components: {len(components)}; largest size: {len(component)}")

    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    box_w = maxx - minx + 1
    box_h = maxy - miny + 1

    print(f"image: {width}x{height}")
    print(f"bbox: x={minx}..{maxx} y={miny}..{maxy} w={box_w} h={box_h}")

    col_top: dict[int, int] = {}
    for x in range(minx, maxx + 1):
        for y in range(miny, maxy + 1):
            if mask[y][x]:
                col_top[x] = y
                break

    row_lr: dict[int, tuple[int, int]] = {}
    for y in range(miny, maxy + 1):
        left = right = None
        for x in range(minx, maxx + 1):
            if mask[y][x]:
                left = x
                break
        for x in range(maxx, minx - 1, -1):
            if mask[y][x]:
                right = x
                break
        if left is not None and right is not None:
            row_lr[y] = (left, right)

    print("\nTop contour samples:")
    for x_norm in [0.00, 0.10, 0.20, 0.275, 0.35, 0.50, 0.65, 0.725, 0.80, 0.90, 1.00]:
        x = minx + round((box_w - 1) * x_norm)
        y = col_top.get(x)
        if y is None:
            print(f"x={x_norm:0.3f}: none")
            continue
        print(f"x={x_norm:0.3f}: y={(y - miny) / (box_h - 1):0.4f} abs=({x},{y})")

    print("\nSide contour samples:")
    for y_norm in [0.00, 0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00]:
        y = miny + round((box_h - 1) * y_norm)
        if y not in row_lr:
            y = min(row_lr, key=lambda candidate: abs(candidate - y))
        left, right = row_lr[y]
        print(
            f"y={y_norm:0.3f}: left={(left - minx) / (box_w - 1):0.4f} "
            f"right={(right - minx) / (box_w - 1):0.4f} width={(right - left) / (box_w - 1):0.4f} "
            f"abs=({left},{right})@{y}"
        )

    top_points = [((col_top[x] - miny) / (box_h - 1), x) for x in sorted(col_top)]
    center_window = [point for point in top_points if 0.40 <= (point[1] - minx) / (box_w - 1) <= 0.60]
    center_crest = min(center_window) if center_window else min(top_points)
    left_scoop_window = [point for point in top_points if 0.18 <= (point[1] - minx) / (box_w - 1) <= 0.40]
    right_scoop_window = [point for point in top_points if 0.60 <= (point[1] - minx) / (box_w - 1) <= 0.82]
    left_scoop = max(left_scoop_window)
    right_scoop = max(right_scoop_window)
    left_shoulder_window = [point for point in top_points if 0.05 <= (point[1] - minx) / (box_w - 1) <= 0.15]
    right_shoulder_window = [point for point in top_points if 0.85 <= (point[1] - minx) / (box_w - 1) <= 0.95]
    left_shoulder = min(left_shoulder_window)
    right_shoulder = min(right_shoulder_window)

    print("\nDerived landmarks:")
    for name, (y_norm, x) in [
        ("left_shoulder", left_shoulder),
        ("left_scoop", left_scoop),
        ("center_crest", center_crest),
        ("right_scoop", right_scoop),
        ("right_shoulder", right_shoulder),
    ]:
        print(f"{name}: x={(x - minx) / (box_w - 1):0.4f} y={y_norm:0.4f} abs=({x},{col_top[x]})")

    for y_norm in [0.045, 0.365, 0.700]:
        y = miny + round((box_h - 1) * y_norm)
        if y not in row_lr:
            y = min(row_lr, key=lambda candidate: abs(candidate - y))
        left, right = row_lr[y]
        print(
            f"anchor y={y_norm:0.3f}: left={(left - minx) / (box_w - 1):0.4f} "
            f"right={(right - minx) / (box_w - 1):0.4f} row={(y - miny) / (box_h - 1):0.4f}"
        )

    tip_left = median([left for y, (left, _) in row_lr.items() if y >= maxy - 2])
    tip_right = median([right for y, (_, right) in row_lr.items() if y >= maxy - 2])
    print(f"tip band: left={(tip_left - minx) / (box_w - 1):0.4f} right={(tip_right - minx) / (box_w - 1):0.4f}")


if __name__ == "__main__":
    main()
