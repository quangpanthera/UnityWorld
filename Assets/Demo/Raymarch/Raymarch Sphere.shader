﻿Shader "Raymarch/Sphere"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            Cull Front
            Blend SrcAlpha OneMinusSrcAlpha
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
        
            #include "UnityCG.cginc"


            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                float3 ro : TEXCOORD1;
                float3 hitPos : TEXCOORD2;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;

#define MAX_STEPS 100
#define MAX_DIST 20
#define SURF_DIST 1e-3//0.001

            float GetDist(float3 p)
            {
                float d = length(p) - 0.5;
                return d;
            }



            float Raymarch(float3 ro, float3 rd) 
            {
                float dO = 0;
                float dS;
                for (int i = 0; i < MAX_STEPS; i++)
                {
                    float3 p = ro + dO * rd;
                    dS = GetDist(p);
                    dO += dS;
                    if (dS<SURF_DIST || dO>MAX_DIST)
                        break;
                }
                return dO;
            }

            float3 GetNormal(float3 p)
            {
                float2 e = float2(.001, 0);
                float3 n = GetDist(p) - float3(
                    GetDist(p - e.xyy),
                    GetDist(p - e.yxy),
                    GetDist(p - e.yyx)
                    );
                return normalize(n);
            }

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.ro = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1));
                o.hitPos = v.vertex;
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                float2 uv = i.uv - .5;
                //ray origin
                //object space camera pos
                float3 ro = i.ro;//float3(0,0,-3);
                //ray direction
                //hit pos 包圍盒邊界
                float3 rd = normalize(i.hitPos - ro);//normalize(float3(uv.x, uv.y, 1));

                float d = Raymarch(ro, rd);
                fixed4 col = 0;

                if (d < MAX_DIST)
                {
                    float3 p = ro + rd * d;
                    float3 n = GetNormal(p);
                    col.rgb = n;
                    col.a = 1;
                }
                else 
                    discard;
                return col;
            }
            ENDCG
        }
    }
}
