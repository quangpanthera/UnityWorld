﻿//see README here: 
//https://github.com/ColinLeung-NiloCat/UnityURPUnlitScreenSpaceDecalShader

Shader "Ren/Effect/Decal"
{
    Properties
    {
        [Header(Basic)]
        _MainTex("Texture", 2D) = "white" {}
        [HDR]_Color("_Color (default = 1,1,1,1)", color) = (1,1,1,1)

        [Header(Alpha remap)]
        //_alpha will first mul x then add y(zw unused)
        _AlphaRemap("_AlphaRemap ", vector) = (1,0,0,0)

        [Header(Prevent Side Stretching(Compare projection direction with scene normal and Discard if needed))]
        [Toggle(_ProjectionAngleDiscardEnable)] _ProjectionAngleDiscardEnable("_ProjectionAngleDiscardEnable (default = on)", float) = 1
        _ProjectionAngleDiscardThreshold("_ProjectionAngleDiscardThreshold (default = 0)", range(-1,1)) = 0

        [Header(Mul alpha to rgb)]
        [Toggle]_MulAlphaToRGB("_MulAlphaToRGB", Float) = 0

        [Header(Ignore texture wrap mode setting)]
        [Toggle(_FracUVEnable)] _FracUVEnable("_FracUVEnable", Float) = 0

        [Header(Unity Fog)]
        [Toggle(_UnityFogEnable)] _UnityFogEnable("_UnityFogEnable", Float) = 1


        //https://docs.unity3d.com/ScriptReference/Rendering.BlendMode.html
        [Header(Blending)]
        [Enum(UnityEngine.Rendering.BlendMode)]
        _SrcBlend("_SrcBlend", Float) = 5 //5 = SrcAlpha
        [Enum(UnityEngine.Rendering.BlendMode)]
        _DstBlend("_DstBlend", Float) = 10 //10 = OneMinusSrcAlpha

        [Header(ZTest)]//https://docs.unity3d.com/ScriptReference/Rendering.CompareFunction.html
        //if camera will inside decal volume box. need set ZTest disable and Cull Front. let decal work correct
        [Enum(UnityEngine.Rendering.CompareFunction)]_ZTest("_ZTest", Float) = 4 //default LEqual

        [Header(Cull)]//https://docs.unity3d.com/ScriptReference/Rendering.CullMode.html
        [Enum(UnityEngine.Rendering.CullMode)]_Cull("_Cull", Float) = 2 //default Back

    }

    SubShader
    {
        Tags { "RenderType" = "Overlay" "Queue" = "AlphaTest+1" }

        Pass
        {
            Cull[_Cull]
            ZTest[_ZTest]

            ZWrite off
            Blend[_SrcBlend][_DstBlend]

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // make fog work
            #pragma multi_compile_fog

            //due to using ddx() & ddy()
            #pragma target 3.0

            #pragma shader_feature_local _ProjectionAngleDiscardEnable
            #pragma shader_feature_local _UnityFogEnable
            #pragma shader_feature_local _FracUVEnable

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
#if _UnityFogEnable
                UNITY_FOG_COORDS(1)
#endif
                float4 screenUV : TEXCOORD0;
                float4 viewRayOS : TEXCOORD2;
                float3 cameraPosOS : TEXCOORD3;
            };

            CBUFFER_START(UnityPerMaterial)
            sampler2D _MainTex;
            float4 _MainTex_ST;
            float _ProjectionAngleDiscardThreshold;
            half4 _Color;
            half2 _AlphaRemap;
            half _MulAlphaToRGB;
            CBUFFER_END

            sampler2D _CameraDepthTexture;

            v2f vert(appdata v)
            {
                v2f o;

                //regular MVP
                o.vertex = UnityObjectToClipPos(v.vertex);

                //regular unity fog
#if _UnityFogEnable
                UNITY_TRANSFER_FOG(o, o.vertex);
#endif

                //prepare depth texture's screen space UV
                o.screenUV = ComputeScreenPos(o.vertex);

                //get "camera to vertex" ray in View space
                float3 viewRay = UnityObjectToViewPos(v.vertex);

                //***WARNING***
                //=========================================================
                //"viewRay z division" must do in the fragment shader, not vertex shader! (due to rasteriazation varying interpolation's perspective correction)
                //We skip the "viewRay z division" in vertex shader for now, and pass the division value to varying o.viewRayOS.w first, we will do the division later when we enter fragment shader
                //viewRay /= viewRay.z; //skip the "viewRay z division" in vertex shader for now
                o.viewRayOS.w = viewRay.z;//pass the division value to varying o.viewRayOS.w
                //=========================================================

                viewRay *= -1; //unity's camera space is right hand coord(negativeZ pointing into screen), we want positive z ray in fragment shader, so negate it

                //it is ok to write very expensive code in decal's vertex shader, it is just a unity cube(4*6 vertices) per decal only, won't affect GPU performance at all.
                //UNITY_MATRIX_I_V. UNITY_MATRIX_V的逆矩陣，用於將頂點/方向矢量從觀察空間變換到世界空間
                float4x4 ViewToObjectMatrix = mul(unity_WorldToObject, UNITY_MATRIX_I_V);

                //transform everything to object space(decal space) in vertex shader first, so we can skip all matrix mul() in fragment shader
                o.viewRayOS.xyz = mul((float3x3)ViewToObjectMatrix, viewRay);

                o.cameraPosOS = mul(ViewToObjectMatrix, float4(0,0,0,1)).xyz;

                return o;
            }

            half4 frag(v2f i) : SV_Target
            {
                //***WARNING***
                //=========================================================
                //now do "viewRay z division" that we skipped in vertex shader earlier.
                i.viewRayOS /= i.viewRayOS.w;
            //=========================================================

            float sceneCameraSpaceDepth = LinearEyeDepth(tex2Dproj(_CameraDepthTexture, i.screenUV));

            //scene depth in any space = rayStartPos + rayDir * rayLength
            //here all data in ObjectSpace(OS) or DecalSpace
            float3 decalSpaceScenePos = i.cameraPosOS + i.viewRayOS * sceneCameraSpaceDepth;

            //convert unity cube's [-0.5,0.5] vertex pos range to [0,1] uv. Only works if you use unity cube in mesh filter!
            float2 decalSpaceUV = decalSpaceScenePos.xy + 0.5;

            //discard logic
            //===================================================
            // discard "out of cube volume" pixels
            float mask = (abs(decalSpaceScenePos.x) < 0.5) * (abs(decalSpaceScenePos.y) < 0.5) * (abs(decalSpaceScenePos.z) < 0.5);

#if _ProjectionAngleDiscardEnable
            // also discard "scene normal not facing decal projector direction" pixels
            float3 decalSpaceHardNormal = normalize(cross(ddx(decalSpaceScenePos), ddy(decalSpaceScenePos)));//reconstruct scene hard normal using scene pos ddx&ddy

            mask *= decalSpaceHardNormal.z > _ProjectionAngleDiscardThreshold;//compare scene hard normal with decal projector's dir, decalSpaceHardNormal.z equals dot(decalForwardDir,sceneHardNormalDir)
#endif
                //call discard
                clip(mask - 0.5);//if ZWrite is off, clip() is fast enough on mobile, because it won't write the DepthBuffer, so no pipeline stall(confirmed by ARM staff).
                //===================================================

                // sample the decal texture
                float2 uv = decalSpaceUV.xy * _MainTex_ST.xy + _MainTex_ST.zw;//Texture tiling & offset
#if _FracUVEnable
                uv = frac(uv);//add frac to ignore texture wrap setting
#endif
                half4 col = tex2D(_MainTex, uv);
                col *= _Color;//tint color
                col.a = saturate(col.a * _AlphaRemap.x + _AlphaRemap.y);//alpha remap MAD
                col.rgb *= lerp(1, col.a, _MulAlphaToRGB);//extra multiply alpha to RGB

#if _UnityFogEnable
                // apply fog
                UNITY_APPLY_FOG(i.fogCoord, col);
#endif

                return col;
            }
            ENDCG
        }
        }
}