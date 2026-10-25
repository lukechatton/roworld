# align.py capture.png out.png W H : find the magenta 4x4 markers, map the stage to W x H
import sys
from PIL import Image
import numpy as np
im=Image.open(sys.argv[1]).convert('RGB')
a=np.asarray(im).astype(int)
mask=(a[...,0]>200)&(a[...,1]<60)&(a[...,2]>200)
ys,xs=np.nonzero(mask)
# two clusters: top-left and bottom-right
tl=(xs<xs.mean())&(ys<ys.mean())
br=~tl
x0,y0=xs[tl].min(),ys[tl].min()
x1,y1=xs[br].max()+1,ys[br].max()+1
W,H=int(sys.argv[3]),int(sys.argv[4])
print('stage in capture', x0,y0,x1,y1, 'scale', (x1-x0)/W, (y1-y0)/H)
im.crop((x0,y0,x1,y1)).resize((W,H),Image.LANCZOS).save(sys.argv[2])
