#pragma language glsl3
extern vec2 cameraJitter;
extern bool temporalOutput;
extern vec3 camPos;
extern vec3 camForward;
extern vec3 camRight;
extern vec3 camUp;
extern float tanHalfHFOV;
extern float tanHalfVFOV;
extern Image heightTex;
extern Image chunkMaxTex;
extern Image spanTex0;
extern Image spanTex1;
extern Image dirtTex;
extern Image grassSideTex;
extern Image grassTopTex;
extern float cacheSize;
extern vec2 cacheOffset;
extern float maxHeight;
extern float viewDist;
extern vec3 skyTint;
extern float starStrength;
extern vec4 cloudParams; // world origin minus drift XY, altitude, enabled
extern vec3 cloudTint;
extern float cloudThickness;
extern vec4 waterParams; // origin modulo 32, phase, normal amplitude
extern float waterAbsorption;
extern vec3 zenithTint;
extern vec3 directTint;
extern vec2 fogRange; // start distance, reciprocal fade length (zero disables)
extern vec3 lightTint;
extern vec3 sunDirection;
extern bool shadowsEnabled;
extern float shadowDistance;
extern float sunStrength;
extern float ambientStrength;
extern float moonStrength;
extern vec4 shadowCacheBounds; // local XY min/max, before texture repeat wrapping
#ifdef SHADOW_STATS
vec4 shadowCounters=vec4(0.0); // cells, skipped chunks, exit reason, complex cells
#endif
vec4 environmentColor(vec3 color) {
#ifdef SHADOW_STATS
  return vec4(0.0);
#else
  return vec4(color,1.0);
#endif
}
vec3 shadowReceiver(vec3 hit,vec3 normal) {
  // Camera origins are multiples of 16 blocks, so this is the world texel grid.
  vec3 p=(floor(hit*16.0)+0.5)/16.0;
  if (normal.x!=0.0) p.x=floor(hit.x+0.5);
  else if (normal.y!=0.0) p.y=floor(hit.y+0.5);
  else p.z=floor(hit.z+0.5);
  return p+normal*0.002;
}
float sunVisibility(vec3 origin,vec3 lightDirection) {
  // Rising rays only. Low sun is handled by the direct-light fade on the CPU.
  float ceilingLimit=max(0.0,(maxHeight-origin.z)/lightDirection.z);
  float limit=min(min(shadowDistance,128.0),ceilingLimit);
#ifdef SHADOW_STATS
  shadowCounters.z=ceilingLimit<=shadowDistance ? 4.0 : 3.0;
#endif
  if (limit<=0.0) return 1.0;
  vec2 cell=floor(origin.xy),stepDir=sign(lightDirection.xy);
  vec2 delta=1.0/max(abs(lightDirection.xy),vec2(1e-20));
  vec2 side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
  vec2 previousChunk=vec2(-1e10),chunkSide=vec2(0.0);
  float entry=0.0,chunkEnd=0.0,chunkHeight=0.0;
  bool complexChunk=false;
  // At most ceil(128*sqrt(2))+2 XY grid crossings; skipping only reduces work.
  for (int i=0;i<184;++i) {
    vec2 chunk=floor(cell/16.0);
    if (any(notEqual(chunk,previousChunk))) {
      if (any(lessThan(cell,shadowCacheBounds.xy)) || any(greaterThanEqual(cell,shadowCacheBounds.zw))) {
#ifdef SHADOW_STATS
        shadowCounters.z=6.0;
#endif
        return 1.0;
      }
      float code=Texel(chunkMaxTex,(chunk+cacheOffset/16.0+0.5)/(cacheSize/16.0)).r;
      // This slot belongs to an incoming, not-yet-uploaded chunk. Never read old data.
      if (code>=1024.0) {
#ifdef SHADOW_STATS
        shadowCounters.z=7.0;
#endif
        return 1.0;
      }
      complexChunk=code>=512.0;chunkHeight=code-(complexChunk ? 512.0 : 0.0);
      chunkSide=(stepDir*(chunk*16.0-origin.xy)+stepDir*8.0+8.0)*delta;
      chunkEnd=min(limit,min(chunkSide.x,chunkSide.y));
      previousChunk=chunk;
    }
    float z=origin.z+lightDirection.z*entry;
    // For a rising ray the entry is the lowest point of the entire chunk segment.
    if (z>=chunkHeight) {
#ifdef SHADOW_STATS
      shadowCounters.y+=1.0;
#endif
      if (chunkEnd>=limit) return 1.0;
      entry=chunkEnd;
      cell=clamp(floor(origin.xy+lightDirection.xy*entry),chunk*16.0,chunk*16.0+15.0);
      if (chunkSide.x<chunkSide.y) cell.x=chunk.x*16.0+(stepDir.x>0.0 ? 16.0 : -1.0);
      else cell.y=chunk.y*16.0+(stepDir.y>0.0 ? 16.0 : -1.0);
      side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
      continue;
    }
    float end=min(limit,min(side.x,side.y));
    if (end>entry) {
#ifdef SHADOW_STATS
      shadowCounters.x+=1.0;
#endif
      vec2 uv=(cell+cacheOffset+0.5)/cacheSize;
      bool blocked=false;
      if (!complexChunk) blocked=z<floor(Texel(heightTex,uv).r/8.0);
      else {
#ifdef SHADOW_STATS
        shadowCounters.w+=1.0;
#endif
        vec4 a=Texel(spanTex0,uv),b=Texel(spanTex1,uv);
        float exitZ=origin.z+lightDirection.z*end;
        for (int span=0;span<4;++span) {
          vec2 bounds=span==0 ? a.xy : span==1 ? a.zw : span==2 ? b.xy : b.zw;
          if (bounds.x<0.0 || bounds.x>=exitZ) break;
          if (bounds.y>bounds.x && z<bounds.y) { blocked=true;break; }
        }
      }
      if (blocked) {
#ifdef SHADOW_STATS
        shadowCounters.z=5.0;
#endif
        return 0.0;
      }
    }
    if (end>=limit) return 1.0;
    entry=end;
    if (side.x<side.y) cell.x+=stepDir.x;else cell.y+=stepDir.y;
    side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
  }
  return 1.0;
}

vec3 skyGradient(vec3 ray) {
  float elevation=clamp(ray.z,0.0,1.0);
  return mix(skyTint,zenithTint,elevation*(2.0-elevation));
}
vec3 atmosphericColor(vec3 color,vec3 ray,float distance) {
  float fog=clamp((distance-fogRange.x)*fogRange.y,0.0,1.0);
  if (fog<=0.0) return color;
  // Match the sky without celestial discs; smooth distance fade, no shadow filtering.
  return mix(color,skyGradient(ray),fog*fog*(3.0-2.0*fog));
}
float skyHash(vec3 p) {
  p=fract(p*0.1031);p+=dot(p,p.yzx+33.33);
  return fract((p.x+p.y)*p.z);
}
float cloudNoise(vec2 p) {
  vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);
  return mix(mix(skyHash(vec3(mod(i,64.0),1)),skyHash(vec3(mod(i+vec2(1,0),64.0),1)),f.x),
    mix(skyHash(vec3(mod(i+vec2(0,1),64.0),1)),skyHash(vec3(mod(i+1.0,64.0),1)),f.x),f.y);
}
vec3 skyAt(vec3 ray,vec3 origin) {
  vec3 sky=skyGradient(ray);
  if (starStrength>0.0 && ray.z>0.015) {
    // Cube-projected, fixed celestial cells: square stars without polar stretching.
    vec3 d=abs(ray);
    float major=max(d.x,max(d.y,d.z));
    vec2 uv=d.z>=max(d.x,d.y) ? ray.xy/d.z : d.x>=d.y ? ray.yz/d.x : ray.xz/d.y;
    float face=d.z>=max(d.x,d.y) ? 1.0 : d.x>=d.y ? (ray.x>0.0 ? 2.0 : 3.0) : (ray.y>0.0 ? 4.0 : 5.0);
    vec2 grid=uv*80.0,cell=floor(grid);
    float seed=skyHash(vec3(cell,face));
    if (seed>0.983) {
      vec2 center=vec2(0.25+0.5*skyHash(vec3(cell,face+7.0)),0.25+0.5*skyHash(vec3(cell,face+13.0)));
      float size=0.055+0.055*seed;
      float pixel=80.0*2.0*tanHalfVFOV/love_ScreenSize.y/major;
      vec2 overlap=clamp((vec2(size)+pixel*0.5-abs(fract(grid)-center))/pixel,0.0,1.0);
      sky+=vec3(0.78,0.85,1.0)*overlap.x*overlap.y*starStrength*smoothstep(0.015,0.15,ray.z);
    }
  }
  vec3 right=vec3(-0.6,0.8,0.0);
  vec2 celestial=vec2(dot(ray,right),dot(ray,cross(right,sunDirection)));
  float facing=dot(ray,sunDirection);
  if (ray.z>0.0) {
    if (facing>0.0 && max(abs(celestial.x),abs(celestial.y))<0.04)
      sky=mix(sky,vec3(1.0,0.94,0.70),smoothstep(0.0,0.08,ray.z));
    if (facing<0.0 && max(abs(celestial.x),abs(celestial.y))<0.028)
      sky=mix(sky,vec3(0.75,0.82,0.94),smoothstep(0.0,0.08,ray.z));
  }
  if (cloudParams.w>0.0 && cloudThickness>0.0) {
    // Intersect a thin slab first; traverse only 16-block cloud columns inside it.
    float bottom=cloudParams.z,ceiling=bottom+cloudThickness;
    float entry=0.0,leave=4096.0;
    vec3 face=vec3(0,0,ray.z>0.0 ? -1.0 : 1.0);
    if (abs(ray.z)>0.000001) {
      float a=(bottom-origin.z)/ray.z,b=(ceiling-origin.z)/ray.z;
      entry=max(0.0,min(a,b));leave=min(leave,max(a,b));
    } else if (origin.z<bottom || origin.z>ceiling) leave=-1.0;
    if (entry<leave) {
      vec2 start=origin.xy+cloudParams.xy;
      vec2 cell=floor((start+ray.xy*entry+sign(ray.xy)*0.0001)/16.0);
      vec2 stepDir=sign(ray.xy),inverse=1.0/max(abs(ray.xy),vec2(1e-20));
      vec2 next=(stepDir*(cell*16.0-start)+stepDir*8.0+8.0)*inverse;
      // Bound covers every XY crossing within 4096 blocks, including diagonal rays.
      for (int i=0;i<364;++i) {
        float end=min(leave,min(next.x,next.y));
        if (end>entry && cloudNoise((cell+0.5)/8.0)>0.52) {
          // Uniform connected faces: no per-tile borders or inset shading.
          float shade=face.z>0.5 ? 1.0 : face.z< -0.5 ? 0.86 : 0.72;
          sky=mix(sky,cloudTint*shade,1.0-smoothstep(1200.0,4096.0,entry));
          break;
        }
        if (end>=leave) break;
        entry=end;
        if (next.x<next.y) {
          cell.x+=stepDir.x;next.x+=16.0*inverse.x;face=vec3(-stepDir.x,0,0);
        } else {
          cell.y+=stepDir.y;next.y+=16.0*inverse.y;face=vec3(0,-stepDir.y,0);
        }
      }
    }
  }
  return sky;
}
vec3 skyColor(vec3 ray) { return skyAt(ray,camPos); }

const vec3 GRASS = vec3(0.32,0.62,0.18);
const vec3 DIRT = vec3(0.43,0.28,0.15);
const vec3 WATER = vec3(0.16,0.51,0.57);
vec3 surfaceColor(float material,bool wall) {
  if (material<0.5) return wall ? DIRT : GRASS;
  if (material<1.5) return vec3(0.76,0.69,0.43);
  if (material<2.5) return vec3(0.43,0.46,0.48);
  if (material<3.5) return wall ? vec3(0.58,0.61,0.64) : vec3(0.9,0.94,0.96);
  return DIRT;
}
float waterAt(vec2 cell) {
  return Texel(heightTex,(cell+cacheOffset+0.5)/cacheSize).g/8.0;
}
float solidAt(vec3 block) {
  if (block.z<0.0) return 1.0;
  vec2 uv=(block.xy+cacheOffset+0.5)/cacheSize;
  float height=floor(Texel(heightTex,uv).r/8.0);
  if (block.z>=height) return 0.0;
  vec2 chunk=floor(block.xy/16.0);
  float code=Texel(chunkMaxTex,(chunk+cacheOffset/16.0+0.5)/(cacheSize/16.0)).r;
  if (code<512.0) return 1.0;
  vec4 a=Texel(spanTex0,uv),b=Texel(spanTex1,uv);
  return ((block.z>=a.x && block.z<a.y) || (block.z>=a.z && block.z<a.w) ||
    (block.z>=b.x && block.z<b.y) || (block.z>=b.z && block.z<b.w)) ? 1.0 : 0.0;
}
float cornerAO(float sideA,float sideB,float diagonal) {
  return sideA*sideB>0.5 ? 0.45 : 1.0-(sideA+sideB+diagonal)*(0.55/3.0);
}
vec3 solidColumn(vec3 block) {
  // Wall AO needs three heights in each of three columns; share their texture reads.
  vec3 z=block.z+vec3(-1.0,0.0,1.0);
  vec2 uv=(block.xy+cacheOffset+0.5)/cacheSize;
  float height=floor(Texel(heightTex,uv).r/8.0);
  vec3 occupied=vec3(1.0)-step(vec3(height),z);
  if (occupied.x==0.0) return occupied;
  vec2 chunk=floor(block.xy/16.0);
  float code=Texel(chunkMaxTex,(chunk+cacheOffset/16.0+0.5)/(cacheSize/16.0)).r;
  if (code<512.0) return occupied;
  vec4 a=Texel(spanTex0,uv),b=Texel(spanTex1,uv);
  vec3 spans=max(max(step(vec3(a.x),z)*(1.0-step(vec3(a.y),z)),step(vec3(a.z),z)*(1.0-step(vec3(a.w),z))),
                 max(step(vec3(b.x),z)*(1.0-step(vec3(b.y),z)),step(vec3(b.z),z)*(1.0-step(vec3(b.w),z))));
  return max(1.0-step(vec3(0.0),z),occupied*spans);
}
float ambientOcclusion(vec3 hit,vec3 normal) {
  // Sample the air layer outside the hit face; never count the face itself.
  vec3 block=floor(hit-normal*0.001),outside=block+normal;
  vec3 u=abs(normal.x)>0.5 ? vec3(0,1,0) : vec3(1,0,0);
  vec3 v=abs(normal.z)>0.5 ? vec3(0,1,0) : vec3(0,0,1);
  vec2 p=clamp(vec2(dot(hit-block,u),dot(hit-block,v)),0.0,1.0);
  if (normal.z==0.0) {
    vec3 left=solidColumn(outside-u),middle=solidColumn(outside),right=solidColumn(outside+u);
    return mix(mix(cornerAO(left.y,middle.x,left.x),cornerAO(right.y,middle.x,right.x),p.x),
               mix(cornerAO(left.y,middle.z,left.z),cornerAO(right.y,middle.z,right.z),p.x),p.y);
  }
  float left=solidAt(outside-u),right=solidAt(outside+u);
  float bottom=solidAt(outside-v),above=solidAt(outside+v);
  return mix(mix(cornerAO(left,bottom,solidAt(outside-u-v)),
                 cornerAO(right,bottom,solidAt(outside+u-v)),p.x),
             mix(cornerAO(left,above,solidAt(outside-u+v)),
                 cornerAO(right,above,solidAt(outside+u+v)),p.x),p.y);
}
float cornerHeight(float a,float b,float c,float d) {
  float total=a,count=1.0,full=-1.0;
  if (ceil(b)==ceil(a) && b>0.0) { total+=b;count+=1.0;if (fract(b)==0.0) full=max(full,b); }
  if (ceil(c)==ceil(a) && c>0.0) { total+=c;count+=1.0;if (fract(c)==0.0) full=max(full,c); }
  if (ceil(d)==ceil(a) && d>0.0) { total+=d;count+=1.0;if (fract(d)==0.0) full=max(full,d); }
  return full>=0.0 ? full : total/count;
}
float surfaceAt(vec4 h,vec2 p) {
  return p.x+p.y<=1.0 ? h.x+(h.y-h.x)*p.x+(h.z-h.x)*p.y
    : h.w+(h.w-h.z)*(p.x-1.0)+(h.w-h.y)*(p.y-1.0);
}
float triangleHit(vec3 ray,vec2 cell,vec4 h,float entry,float end) {
  vec2 p=camPos.xy-cell;
  vec2 slope=vec2(h.y-h.x,h.z-h.x);
  float denominator=ray.z-dot(slope,ray.xy);
  float t=abs(denominator)>1e-8 ? (h.x+dot(slope,p)-camPos.z)/denominator : viewDist+1.0;
  vec2 q=p+ray.xy*t;
  float hit=t>=entry-0.00001 && t<=end+0.00001 && q.x+q.y<=1.00001 ? t : viewDist+1.0;
  slope=vec2(h.w-h.z,h.w-h.y);
  denominator=ray.z-dot(slope,ray.xy);
  t=abs(denominator)>1e-8 ? (h.w+dot(slope,p-1.0)-camPos.z)/denominator : viewDist+1.0;
  q=p+ray.xy*t;
  if (t>=entry-0.00001 && t<=end+0.00001 && q.x+q.y>=0.99999) hit=min(hit,t);
  return hit;
}
#ifdef AA_STATS
float geometryTraces=0.0;
#endif
struct Hit {
  bool valid;
  float distance;
  vec3 position;
  vec3 normal;
  vec2 voxel;
  float surface;
  float material;
  float textureID;
  int kind; // sky, solid, water
};
Hit makeHit(vec3 origin,vec3 ray,float distance,vec3 normal,vec2 cell,float surface,float material,float textureID,int kind) {
  return Hit(kind!=0,distance,origin+ray*distance,normal,cell,surface,material,textureID,kind);
}
Hit traceRay(vec3 origin,vec3 ray,float limit,bool includeWater) {
#ifdef AA_STATS
  geometryTraces+=1.0;
#endif
  if (origin.z>maxHeight && ray.z>=0.0) return makeHit(origin,ray,limit,vec3(0),vec2(0),0.0,0.0,-1.0,0);
  vec2 cell=floor(origin.xy);
  vec2 stepDir=sign(ray.xy);
  vec2 delta=1.0/max(abs(ray.xy),vec2(1e-8));
  vec2 side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
  float entry=0.0;
  vec2 normal=vec2(0.0);
  vec2 previousChunk=vec2(-1e10);
  float chunkHeight=maxHeight;
  vec2 chunkSide=vec2(0.0);
  float chunkEnd=0.0;
  bool complexChunk=false;
  float previousWater=0.0;
  bool previousCavity=false;

  for (int i=0;i<MAX_DDA_STEPS;++i) {
    vec2 chunk=floor(cell/16.0);
    if (any(notEqual(chunk,previousChunk))) {
      if (!includeWater && (any(lessThan(cell,shadowCacheBounds.xy)) ||
          any(greaterThanEqual(cell,shadowCacheBounds.zw)))) break;
      chunkHeight=Texel(chunkMaxTex,(chunk+cacheOffset/16.0+0.5)/(cacheSize/16.0)).r;
      if (!includeWater && chunkHeight>=1024.0) break;
      complexChunk=chunkHeight>=512.0;
      chunkHeight-=complexChunk ? 512.0 : 0.0;
      chunkSide=(stepDir*(chunk*16.0-origin.xy)+stepDir*8.0+8.0)*delta;
      chunkEnd=min(limit,min(chunkSide.x,chunkSide.y));
      previousChunk=chunk;
    }
    // Skip whole chunks only when entire ray segment clears their highest block.
    if (min(origin.z+ray.z*entry,origin.z+ray.z*chunkEnd)>chunkHeight+0.00001) {
      if (chunkEnd>=limit) break;
      entry=chunkEnd;
      cell=clamp(floor(origin.xy+ray.xy*entry),chunk*16.0,chunk*16.0+15.0);
      if (chunkSide.x<chunkSide.y) cell.x=chunk.x*16.0+(stepDir.x>0.0 ? 16.0 : -1.0);
      else cell.y=chunk.y*16.0+(stepDir.y>0.0 ? 16.0 : -1.0);
      side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
      normal=chunkSide.x<chunkSide.y ? vec2(-stepDir.x,0.0) : vec2(0.0,-stepDir.y);
      previousWater=0.0;previousCavity=false;
      continue;
    }
    float end=min(limit,min(side.x,side.y));
    vec2 geometry=Texel(heightTex,(cell+cacheOffset+0.5)/cacheSize).rg;
    float terrainCode=geometry.r; // Uploaded integer codes are exact in RG16F/RG32F.
    float height=floor(terrainCode/8.0);
    float material=terrainCode-height*8.0;
    float water=geometry.g/8.0;
    float z=origin.z+ray.z*entry;
    bool wall=dot(normal,normal)>0.0 && z<height-0.00001;
    float top=ray.z<0.0 ? (height-origin.z)/ray.z : limit+1.0;
    bool underside=false;
    float surfaceID=0.0;
    if (complexChunk) {
      vec2 uv=(cell+cacheOffset+0.5)/cacheSize;
      vec4 spans0=Texel(spanTex0,uv),spans1=Texel(spanTex1,uv);
      top=limit+1.0;wall=false;
      float hitMaterial=material;
      for (int span=0;span<4;++span) {
        vec2 bounds=span==0 ? spans0.xy : span==1 ? spans0.zw : span==2 ? spans1.xy : spans1.zw;
        if (bounds.x<0.0) break;
        if (bounds.y<=bounds.x) continue;
        bool spanWall=dot(normal,normal)>0.0 && z>=bounds.x && z<bounds.y-0.00001;
        float hit=spanWall ? entry : abs(ray.z)>1e-8 ? ((ray.z<0.0 ? bounds.y : bounds.x)-origin.z)/ray.z : limit+1.0;
        if (hit>=entry && hit<=end && hit<top) {
          surfaceID=float(span);
          top=hit;wall=spanWall;underside=!spanWall && ray.z>0.0;
          bool surface=bounds.y==height && (bounds.x==0.0 || (!spanWall && ray.z<0.0) || (spanWall && z>height-2.0));
          hitMaterial=surface && !(previousCavity && spanWall && z<height-2.0) ? material : 2.0;
        }
      }
      material=hitMaterial;
    }
    if (previousCavity && wall && z<height-2.0) material=2.0;
    float waterHit=water>height && abs(ray.z)>1e-8 ? (water-origin.z)/ray.z : limit+1.0;
    float edgeWater=water,exitWater=water;
    // Dry traversal pays no neighbor reads. Full/ocean surfaces stay exactly flat.
    if (includeWater && water>height && fract(water)>0.0 && !wall && min(z,origin.z+ray.z*end)<=ceil(water) && max(z,origin.z+ray.z*end)>=floor(water)) {
      float west=waterAt(cell+vec2(-1,0)),east=waterAt(cell+vec2(1,0));
      float north=waterAt(cell+vec2(0,-1)),south=waterAt(cell+vec2(0,1));
      vec4 corners=vec4(cornerHeight(water,west,north,waterAt(cell+vec2(-1,-1))),
        cornerHeight(water,east,north,waterAt(cell+vec2(1,-1))),
        cornerHeight(water,west,south,waterAt(cell+vec2(-1,1))),
        cornerHeight(water,east,south,waterAt(cell+vec2(1,1))));
      waterHit=triangleHit(ray,cell,corners,entry,end);
      edgeWater=surfaceAt(corners,clamp(origin.xy+ray.xy*entry-cell,0.0,1.0));
      exitWater=surfaceAt(corners,clamp(origin.xy+ray.xy*end-cell,0.0,1.0));
    }
    // A level change exposes the water volume's vertical face (explicit drop).
    bool waterfall=dot(normal,normal)>0.0 && z>height &&
      ((water>height && z<edgeWater && z>=previousWater) || (previousWater>z && edgeWater<=z));
    if (includeWater && waterfall && !wall) return makeHit(origin,ray,entry,vec3(normal,0),cell,max(max(edgeWater,previousWater)-height,0.0),material,-1.0,2);
    if (includeWater && waterHit>=entry && waterHit<=end && !wall && (top<entry || waterHit<top)) {
      return makeHit(origin,ray,waterHit,vec3(0,0,1),cell,max(origin.z+ray.z*waterHit-height,0.0),material,-1.0,2);
    }
    if (wall || (top>=entry && top<=end)) {
      float textureID=-1.0;
      if (material<0.5 || material>=3.5)
        textureID=material>=3.5 || underside ? 0.0 : wall ? (z>=height-1.0 ? 1.0 : 0.0) : 2.0;
      return makeHit(origin,ray,wall ? entry : top,wall ? vec3(normal,0) : vec3(0,0,underside ? -1.0 : 1.0),cell,surfaceID,material,textureID,1);
    }
    if (end>=limit) break;
    previousWater=exitWater;
    previousCavity=complexChunk && origin.z+ray.z*end<height;
    entry=end;
    if (side.x<side.y) {
      cell.x+=stepDir.x; normal=vec2(-stepDir.x,0.0);
    } else {
      cell.y+=stepDir.y; normal=vec2(0.0,-stepDir.y);
    }
    side=(stepDir*(cell-origin.xy)+stepDir*0.5+0.5)*delta;
    if (ray.z>=0.0 && origin.z+ray.z*entry>maxHeight) break;
  }
  return makeHit(origin,ray,limit,vec3(0),vec2(0),0.0,0.0,-1.0,0);
}
#ifdef AA_STATS
vec2 shadingCounters=vec2(0); // shadow rays, AO evaluations
#endif
vec3 shadeSolid(Hit h,vec3 ray,bool detailed) {
  vec3 hit=h.position,normal=h.normal;
  vec3 base=surfaceColor(h.material,normal.z==0.0);
  if (h.textureID>=0.0) {
    // Sample texel centers: nearest pixel art, no derivative LOD or filtering.
    vec3 grid=(floor(hit*16.0)+0.5)/16.0;
    vec2 uv=normal.z!=0.0 ? fract(grid.xy) : vec2(fract(normal.x!=0.0 ? grid.y : grid.x),1.0-fract(grid.z));
    base=h.textureID<0.5 ? textureLod(dirtTex,uv,0.0).rgb :
      h.textureID<1.5 ? textureLod(grassSideTex,uv,0.0).rgb : textureLod(grassTopTex,uv,0.0).rgb;
  }
  vec3 lightDirection=sunDirection.z>=0.0 ? sunDirection : -sunDirection;
  float directStrength=sunDirection.z>=0.0 ? sunStrength : moonStrength;
  float ndotl=max(dot(normal,lightDirection),0.0),visibility=1.0;
  if (detailed && ndotl>0.0 && directStrength>0.0 && lightDirection.z>0.20791169 && shadowsEnabled && shadowDistance>0.0) {
#ifdef AA_STATS
    shadingCounters.x+=1.0;
#endif
    visibility=sunVisibility(shadowReceiver(hit,normal),lightDirection);
  }
#ifdef SHADOW_STATS
  if (shadowCounters.z==0.0) shadowCounters.z=ndotl<=0.0 ? 1.0 : 2.0;
#endif
#ifdef AA_STATS
  shadingCounters.y+=1.0;
#endif
  vec3 lighting=lightTint*ambientStrength+directTint*(directStrength*ndotl*visibility);
  return base*lighting*(detailed ? ambientOcclusion(hit,normal) : 1.0);
}
vec3 shadeWater(Hit h,vec3 ray) {
  vec3 n=h.normal;
  float top=abs(n.z);
  if (top>0.5) {
    vec2 p=h.position.xy+waterParams.xy;
    float footprint=h.distance*2.0*tanHalfVFOV/love_ScreenSize.y;
    float amplitude=waterParams.w*0.2/(1.0+footprint*footprint*4.0);
    float a=cos(dot(p,vec2(1,2))*0.3926990817+waterParams.z*2.0);
    float b=cos(dot(p,vec2(-2,1))*0.1963495408-waterParams.z*3.0);
    n=normalize(vec3(amplitude*(a-0.6*b),amplitude*(0.6*a+b),1.0));
  }
  // Stable geometric normal controls reflected geometry and its blend weight.
  // Animated normals only bend transmission slightly, never warp distant mountains.
  float facing=clamp(abs(dot(-ray,h.normal)),0.0,1.0);
  float grazing=1.0-facing,g2=grazing*grazing;
  float reflection=0.12+0.88*g2*g2*grazing;
  if ((h.distance-fogRange.x)*fogRange.y>=1.0) return skyGradient(ray);
  vec3 lightDirection=sunDirection.z>=0.0 ? sunDirection : -sunDirection;
  float strength=sunDirection.z>=0.0 ? sunStrength : moonStrength;
  vec3 illumination=lightTint*ambientStrength+directTint*(strength*max(lightDirection.z,0.0));
  vec3 deep=vec3(0.025,0.105,0.24)*illumination;
  bool entering=dot(ray,h.normal)<0.0;
  vec3 oriented=entering ? n : -n;
  vec3 refractionRay=refract(ray,oriented,entering ? 0.7501875 : 1.333);
  vec3 transmitted=deep;
  if (dot(refractionRay,refractionRay)>0.0) {
    // Stop once even the least-absorbed channel is negligible, with a hard cap.
    float absorption=max(waterAbsorption,0.02);
    float waterLimit=min(96.0,12.0/(0.45*absorption));
    Hit bed=traceRay(h.position+(entering ? -h.normal : h.normal)*0.002,refractionRay,waterLimit,false);
    if (bed.valid) {
      vec3 transmission=exp2(-vec3(1.7,0.75,0.45)*bed.distance*absorption);
      transmitted=mix(deep,shadeSolid(bed,refractionRay,false),transmission);
    }
  } else reflection=1.0; // Total internal reflection when viewed from below.
  vec3 reflectionRay=reflect(ray,h.normal);
  Hit reflectedHit=traceRay(h.position+(entering ? h.normal : -h.normal)*0.002,reflectionRay,viewDist,false);
  vec3 reflected=skyAt(reflectionRay,h.position);
  if (reflectedHit.valid)
    reflected=atmosphericColor(shadeSolid(reflectedHit,reflectionRay,false),reflectionRay,reflectedHit.distance);
  reflection*=mix(0.25,1.0,top);
  // Tint the water body, not the reflected landscape: preserve reflection contrast.
  vec3 body=mix(transmitted*vec3(0.65,0.78,0.95),deep,0.18);
  vec3 waterColor=mix(body,reflected,reflection);
  return atmosphericColor(waterColor,ray,h.distance);
}
vec3 shadeHit(Hit h,vec3 ray) {
  if (h.kind==0) return skyColor(ray);
  if (h.kind==2) return shadeWater(h,ray);
  return atmosphericColor(shadeSolid(h,ray,true),ray,h.distance);
}
vec4 effect(vec4 color,Image dummy,vec2 tc,vec2 sc) {
  vec2 ndc=(sc+cameraJitter)/love_ScreenSize.xy*2.0-1.0;
  vec3 ray=normalize(camForward+camRight*(ndc.x*tanHalfHFOV)-camUp*(ndc.y*tanHalfVFOV));
  Hit h=traceRay(camPos,ray,viewDist,true);
  vec3 shaded=shadeHit(h,ray);
#ifdef AA_STATS
  return vec4(1.0,shadingCounters,geometryTraces);
#elif defined(SHADOW_STATS)
  return shadowCounters;
#else
  // Signed forward depth identifies sky (0), solid (+) and moving water (-).
  float depth=h.kind==0 ? 0.0 : max(0.001,h.distance*dot(ray,camForward))*(h.kind==2 ? -1.0 : 1.0);
  return vec4(shaded,temporalOutput ? depth : 1.0);
#endif
}
