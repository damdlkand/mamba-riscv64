import tkinter as tk
import numpy as np, time

W, H = 600, 400
N = 20
rng = np.random.default_rng(0)
pos = rng.uniform([20,20], [W-20,H-20], (N,2))
vel = rng.uniform(-120, 120, (N,2))  # px/s
rad = rng.integers(8, 16, size=N)

root = tk.Tk()
root.title("NumPy + Tkinter: bouncing balls")
cv = tk.Canvas(root, width=W, height=H, bg="black")
cv.pack()

items = []
colors = ["#%06x"%c for c in rng.integers(0, 0xFFFFFF, size=N)]
for i in range(N):
    r = rad[i]
    x, y = pos[i]
    it = cv.create_oval(x-r, y-r, x+r, y+r, fill=colors[i], width=0)
    items.append(it)

last = time.time()
def tick():
    global pos, vel, last
    now = time.time()
    dt = now - last
    last = now

    pos += vel * dt
    # 碰撞墙反弹
    for axis, lim in ((0, W), (1, H)):
        hit_lo = pos[:,axis] - rad < 0
        hit_hi = pos[:,axis] + rad > lim
        vel[hit_lo | hit_hi, axis] *= -1
        pos[:,axis] = np.clip(pos[:,axis], rad, lim - rad)

    for i in range(N):
        r = rad[i]; x, y = pos[i]
        cv.coords(items[i], x-r, y-r, x+r, y+r)

    root.after(16, tick)  # ~60 FPS

root.after(0, tick)
root.mainloop()

