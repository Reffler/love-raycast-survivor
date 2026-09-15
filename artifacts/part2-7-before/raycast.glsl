extern vec3 camPos;
extern vec3 camForward;
extern vec3 camRight;
extern vec3 camUp;
extern float tanHalfHFOV;
extern float tanHalfVFOV;
extern Image heightTex;
extern Image chunkMaxTex;
extern float cacheSize;
extern vec2 cacheOffset;
extern float maxHeight;
extern float viewDist;
const vec3 SKY = vec3(0.48,0.72,0.92);
const vec3 GRASS = vec3(0.32,0.62,0.18);
const vec3 DIRT = vec3(0.43,0.28,0.15);
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
  float previousWater=0.0;
  for (int i=0;i<MAX_DDA_STEPS;++i) {
    vec2 chunk=floor(cell/16.0);
    if (any(notEqual(chunk,previousChunk))) {
      chunkHeight=Texel(chunkMaxTex,(mod(chunk+cacheOffset/16.0,cacheSize/16.0)+0.5)/(cacheSize/16.0)).r;
      previousChunk=chunk;
    }
    // Skip whole chunks only when entire ray segment clears their highest block.
    vec2 chunkSide=(stepDir*(chunk*16.0-camPos.xy)+stepDir*8.0+8.0)*delta;
    float chunkEnd=min(viewDist,min(chunkSide.x,chunkSide.y));
    if (min(camPos.z+ray.z*entry,camPos.z+ray.z*chunkEnd)>chunkHeight+0.00001) {
      if (chunkEnd>=viewDist) break;
      entry=chunkEnd;
      cell=clamp(floor(camPos.xy+ray.xy*entry),chunk*16.0,chunk*16.0+15.0);
      if (chunkSide.x<chunkSide.y) cell.x=chunk.x*16.0+(stepDir.x>0.0 ? 16.0 : -1.0);
      else cell.y=chunk.y*16.0+(stepDir.y>0.0 ? 16.0 : -1.0);
      side=(stepDir*(cell-camPos.xy)+stepDir*0.5+0.5)*delta;
      normal=chunkSide.x<chunkSide.y ? vec2(-stepDir.x,0.0) : vec2(0.0,-stepDir.y);
      previousWater=0.0;
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
    if (waterfall && !wall) return vec4(0.13,0.40,0.53,1.0);
    if (waterHit>=entry && waterHit<=end && !wall && (top<entry || waterHit<top)) {
      float deep=clamp((water-height)/14.0,0.0,1.0);
      return vec4(mix(vec3(0.16,0.51,0.57),vec3(0.08,0.27,0.48),deep),1.0);
    }
    if (wall || (top>=entry && top<=end)) {
      vec3 base=surfaceColor(material,wall);
      float light=wall ? (normal.x<0.0 ? 0.72 : normal.x>0.0 ? 0.58 : normal.y<0.0 ? 0.64 : 0.82) : 1.0;
      return vec4(base*light,1.0);
    }
    if (end>=viewDist) break;
    previousWater=exitWater;
    entry=end;
    if (side.x<side.y) {
      cell.x+=stepDir.x; normal=vec2(-stepDir.x,0.0);
    } else {
      cell.y+=stepDir.y; normal=vec2(0.0,-stepDir.y);
    }
    side=(stepDir*(cell-camPos.xy)+stepDir*0.5+0.5)*delta;
    if (ray.z>=0.0 && camPos.z+ray.z*entry>maxHeight) break;
  }
  return vec4(SKY,1.0);
}
