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
extern float cacheSize;
extern vec2 cacheOffset;
extern float maxHeight;
extern float viewDist;
const vec3 SKY = vec3(0.48,0.72,0.92);
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
  return Texel(heightTex,(mod(cell+cacheOffset,cacheSize)+0.5)/cacheSize).g/8.0;
}
float solidAt(vec3 block) {
  if (block.z<0.0) return 1.0;
  vec2 uv=(mod(block.xy+cacheOffset,cacheSize)+0.5)/cacheSize;
  float height=floor(Texel(heightTex,uv).r/8.0);
  if (block.z>=height) return 0.0;
  vec2 chunk=floor(block.xy/16.0);
  float code=Texel(chunkMaxTex,(mod(chunk+cacheOffset/16.0,cacheSize/16.0)+0.5)/(cacheSize/16.0)).r;
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
  vec2 uv=(mod(block.xy+cacheOffset,cacheSize)+0.5)/cacheSize;
  float height=floor(Texel(heightTex,uv).r/8.0);
  vec3 occupied=vec3(1.0)-step(vec3(height),z);
  if (occupied.x==0.0) return occupied;
  vec2 chunk=floor(block.xy/16.0);
  float code=Texel(chunkMaxTex,(mod(chunk+cacheOffset/16.0,cacheSize/16.0)+0.5)/(cacheSize/16.0)).r;
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
vec4 effect(vec4 color, Image dummy, vec2 tc, vec2 sc) {
  vec2 ndc = sc/love_ScreenSize.xy*2.0-1.0;
  ndc.y = -ndc.y;
  vec3 ray = normalize(camForward+camRight*(ndc.x*tanHalfHFOV)+camUp*(ndc.y*tanHalfVFOV));
  if (camPos.z>maxHeight && ray.z>=0.0) return vec4(SKY,1.0);
  vec2 cell=floor(camPos.xy);
  vec2 stepDir=sign(ray.xy);
  vec2 delta=1.0/max(abs(ray.xy),vec2(1e-8));
  vec2 side=(stepDir*(cell-camPos.xy)+stepDir*0.5+0.5)*delta;
  float entry=0.0;
  vec2 normal=vec2(0.0);
  vec2 previousChunk=vec2(-1e10);
  float chunkHeight=maxHeight;
  vec2 chunkSide=vec2(0.0);
  float chunkEnd=0.0;
  bool complexChunk=false;
  float previousWater=0.0;
  bool previousCavity=false;
  float solidHit=-1.0;
  vec3 solidNormal=vec3(0.0),solidColor=vec3(0.0);
  for (int i=0;i<MAX_DDA_STEPS;++i) {
    vec2 chunk=floor(cell/16.0);
    if (any(notEqual(chunk,previousChunk))) {
      chunkHeight=Texel(chunkMaxTex,(mod(chunk+cacheOffset/16.0,cacheSize/16.0)+0.5)/(cacheSize/16.0)).r;
      complexChunk=chunkHeight>=512.0;
      chunkHeight=mod(chunkHeight,512.0);
      chunkSide=(stepDir*(chunk*16.0-camPos.xy)+stepDir*8.0+8.0)*delta;
      chunkEnd=min(viewDist,min(chunkSide.x,chunkSide.y));
      previousChunk=chunk;
    }
    // Skip whole chunks only when entire ray segment clears their highest block.
    if (min(camPos.z+ray.z*entry,camPos.z+ray.z*chunkEnd)>chunkHeight+0.00001) {
      if (chunkEnd>=viewDist) break;
      entry=chunkEnd;
      cell=clamp(floor(camPos.xy+ray.xy*entry),chunk*16.0,chunk*16.0+15.0);
      if (chunkSide.x<chunkSide.y) cell.x=chunk.x*16.0+(stepDir.x>0.0 ? 16.0 : -1.0);
      else cell.y=chunk.y*16.0+(stepDir.y>0.0 ? 16.0 : -1.0);
      side=(stepDir*(cell-camPos.xy)+stepDir*0.5+0.5)*delta;
      normal=chunkSide.x<chunkSide.y ? vec2(-stepDir.x,0.0) : vec2(0.0,-stepDir.y);
      previousWater=0.0;previousCavity=false;
      continue;
    }
    float end=min(viewDist,min(side.x,side.y));
    vec2 geometry=Texel(heightTex,(mod(cell+cacheOffset,cacheSize)+0.5)/cacheSize).rg;
    float terrainCode=floor(geometry.r+0.5);
    float height=floor(terrainCode/8.0);
    float material=mod(terrainCode,8.0);
    float water=geometry.g/8.0;
    float z=camPos.z+ray.z*entry;
    bool wall=dot(normal,normal)>0.0 && z<height-0.00001;
    float top=ray.z<0.0 ? (height-camPos.z)/ray.z : viewDist+1.0;
    bool underside=false;
    if (complexChunk) {
      vec2 uv=(mod(cell+cacheOffset,cacheSize)+0.5)/cacheSize;
      vec4 spans0=Texel(spanTex0,uv),spans1=Texel(spanTex1,uv);
      top=viewDist+1.0;wall=false;
      float hitMaterial=material;
      for (int span=0;span<4;++span) {
        vec2 bounds=span==0 ? spans0.xy : span==1 ? spans0.zw : span==2 ? spans1.xy : spans1.zw;
        if (bounds.x<0.0 || bounds.y<=bounds.x) continue;
        bool spanWall=dot(normal,normal)>0.0 && z>=bounds.x && z<bounds.y-0.00001;
        float hit=spanWall ? entry : abs(ray.z)>1e-8 ? ((ray.z<0.0 ? bounds.y : bounds.x)-camPos.z)/ray.z : viewDist+1.0;
        if (hit>=entry && hit<=end && hit<top) {
          top=hit;wall=spanWall;underside=!spanWall && ray.z>0.0;
          bool surface=bounds.y==height && (bounds.x==0.0 || (!spanWall && ray.z<0.0) || (spanWall && z>height-2.0));
          hitMaterial=surface && !(previousCavity && spanWall && z<height-2.0) ? material : 2.0;
        }
      }
      material=hitMaterial;
    }
    if (previousCavity && wall && z<height-2.0) material=2.0;
    float waterHit=water>height && abs(ray.z)>1e-8 ? (water-camPos.z)/ray.z : viewDist+1.0;
    float edgeWater=water,exitWater=water;
    // Dry traversal pays no neighbor reads. Full/ocean surfaces stay exactly flat.
    if (water>height && fract(water)>0.0 && !wall && min(z,camPos.z+ray.z*end)<=ceil(water) && max(z,camPos.z+ray.z*end)>=floor(water)) {
      float west=waterAt(cell+vec2(-1,0)),east=waterAt(cell+vec2(1,0));
      float north=waterAt(cell+vec2(0,-1)),south=waterAt(cell+vec2(0,1));
      vec4 corners=vec4(cornerHeight(water,west,north,waterAt(cell+vec2(-1,-1))),
        cornerHeight(water,east,north,waterAt(cell+vec2(1,-1))),
        cornerHeight(water,west,south,waterAt(cell+vec2(-1,1))),
        cornerHeight(water,east,south,waterAt(cell+vec2(1,1))));
      waterHit=triangleHit(ray,cell,corners,entry,end);
      edgeWater=surfaceAt(corners,clamp(camPos.xy+ray.xy*entry-cell,0.0,1.0));
      exitWater=surfaceAt(corners,clamp(camPos.xy+ray.xy*end-cell,0.0,1.0));
    }
    // A level change exposes the water volume's vertical face (explicit drop).
    bool waterfall=dot(normal,normal)>0.0 && z>height &&
      ((water>height && z<edgeWater && z>=previousWater) || (previousWater>z && edgeWater<=z));
    if (waterfall && !wall) return vec4(WATER,1.0);
    if (waterHit>=entry && waterHit<=end && !wall && (top<entry || waterHit<top)) {
      return vec4(WATER,1.0);
    }
    if (wall || (top>=entry && top<=end)) {
      vec3 base=surfaceColor(material,wall);
      float light=wall ? (normal.x<0.0 ? 0.72 : normal.x>0.0 ? 0.58 : normal.y<0.0 ? 0.64 : 0.82) : underside ? 0.64 : 1.0;
      solidHit=wall ? entry : top;
      solidNormal=wall ? vec3(normal,0.0) : vec3(0.0,0.0,underside ? -1.0 : 1.0);
      solidColor=base*light;
      break;
    }
    if (end>=viewDist) break;
    previousWater=exitWater;
    previousCavity=complexChunk && camPos.z+ray.z*end<height;
    entry=end;
    if (side.x<side.y) {
      cell.x+=stepDir.x; normal=vec2(-stepDir.x,0.0);
    } else {
      cell.y+=stepDir.y; normal=vec2(0.0,-stepDir.y);
    }
    side=(stepDir*(cell-camPos.xy)+stepDir*0.5+0.5)*delta;
    if (ray.z>=0.0 && camPos.z+ray.z*entry>maxHeight) break;
  }
  if (solidHit>=0.0) return vec4(solidColor*ambientOcclusion(camPos+ray*solidHit,solidNormal),1.0);
  return vec4(SKY,1.0);
}
