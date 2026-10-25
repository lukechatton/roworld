import sys
from PIL import Image, ImageOps
import numpy as np
mine=Image.open(sys.argv[1]).convert('L').resize((1600,900), Image.LANCZOS)
ref=Image.open('/private/tmp/airfront-ui/hud_desktop.png').convert('L')
box=tuple(int(v) for v in sys.argv[3].split(','))
k=int(sys.argv[4]) if len(sys.argv)>4 else 3
a=np.asarray(ref.crop(box)).astype(float); b=np.asarray(mine.crop(box)).astype(float)
rgb=np.zeros(a.shape+(3,),np.uint8)
rgb[...,0]=np.clip(a,0,255); rgb[...,1]=np.clip(b,0,255); rgb[...,2]=np.clip(b,0,255)
im=Image.fromarray(rgb)
im=im.resize((im.width*k, im.height*k), Image.NEAREST)
im.save(sys.argv[2])
