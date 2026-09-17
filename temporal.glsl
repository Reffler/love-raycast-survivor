#pragma language glsl3
extern Image currentFrame;
extern Image historyFrame;
extern vec2 inverseSize;
extern vec2 projection;
extern vec3 forward;
extern vec3 right;
extern vec3 up;
extern vec3 previousForward;
extern vec3 previousRight;
extern vec3 previousUp;
extern vec3 cameraDelta; // Current minus previous world camera; independent of cache origin.
extern bool historyValid;
extern float historyWeight;

vec4 effect(vec4 color,Image unused,vec2 uv,vec2 sc) {
  ivec2 pixel=ivec2(sc);
  vec4 current=texelFetch(currentFrame,pixel,0);
  if (!historyValid) return current;
  vec2 ndc=sc*inverseSize*2.0-1.0;
  vec3 direction=forward+right*(ndc.x*projection.x)-up*(ndc.y*projection.y);
  bool sky=current.a==0.0;
  vec3 relative=sky ? direction : direction*abs(current.a)+cameraDelta;
  float expected=dot(relative,previousForward);
  if (expected<=0.0) return current;
  vec2 previousNDC=vec2(dot(relative,previousRight),-dot(relative,previousUp))/(expected*projection);
  vec2 previousPixel=(previousNDC*0.5+0.5)/inverseSize;
  if (any(lessThan(previousPixel,vec2(0.5))) || any(greaterThan(previousPixel,1.0/inverseSize-0.5))) return current;

  // History is accumulated on the unjittered pixel grid. Current depth may come
  // from anywhere inside that pixel; use its local surface depth interval when
  // judging history, otherwise alternating top/side samples continually reset it.
  ivec2 maximum=textureSize(historyFrame,0)-1;
  vec3 low=current.rgb,high=current.rgb;
  float nearDepth=abs(current.a),farDepth=abs(current.a);
  bool hasSky=sky,hasSolid=current.a>0.0;
  for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
    vec4 neighbor=texelFetch(currentFrame,clamp(pixel+ivec2(x,y),ivec2(0),maximum),0);
    low=min(low,neighbor.rgb);high=max(high,neighbor.rgb);
    hasSky=hasSky || neighbor.a==0.0;hasSolid=hasSolid || neighbor.a>0.0;
    if (sign(neighbor.a)==sign(current.a)) {
      nearDepth=min(nearDepth,abs(neighbor.a));farDepth=max(farDepth,abs(neighbor.a));
    }
  }
  float depthScale=sky ? 1.0 : dot(direction,previousForward);
  float depthOffset=sky ? 0.0 : dot(cameraDelta,previousForward);
  float tolerance=max(0.06,expected*0.003);
  float minimumDepth=nearDepth*depthScale+depthOffset-tolerance;
  float maximumDepth=farDepth*depthScale+depthOffset+tolerance;

  // Validate each bilinear tap separately, preventing foreground/background leaks.
  vec2 samplePosition=previousPixel-0.5;
  ivec2 corner=ivec2(floor(samplePosition));
  vec2 fraction=fract(samplePosition);
  vec3 history=vec3(0.0);float weight=0.0;
  for (int y=0;y<2;++y) for (int x=0;x<2;++x) {
    vec4 sampleColor=texelFetch(historyFrame,clamp(corner+ivec2(x,y),ivec2(0),maximum),0);
    bool silhouette=hasSky && hasSolid && sampleColor.a>=0.0 && current.a>=0.0;
    bool valid=silhouette || (sky ? sampleColor.a==0.0 : sign(sampleColor.a)==sign(current.a) &&
      abs(sampleColor.a)>=minimumDepth && abs(sampleColor.a)<=maximumDepth);
    float w=(x==0 ? 1.0-fraction.x : fraction.x)*(y==0 ? 1.0-fraction.y : fraction.y);
    if (valid) { history+=sampleColor.rgb*w;weight+=w; }
  }
  if (weight<0.05) return current;
  history/=weight;

  // Reject stale lighting while preserving thin-line coverage in edge neighborhoods.
  history=clamp(history,low,high);
  // Water moves independently of camera reprojection: short history avoids trails.
  float blend=current.a<0.0 ? min(historyWeight,0.5) : historyWeight;
  return vec4(mix(current.rgb,history,blend),current.a);
}
