#ifndef PS1_FILTER_MMPX_ADVANCED_H
#define PS1_FILTER_MMPX_ADVANCED_H

/* =========================================================================
 * MMPX Advanced v3.2
 * =========================================================================
 * An optimized and heavily expanded derivative of the MMPX algorithm.
 * 
 * The baseline MMPX implementation relies on a minimalist rule-set, which 
 * inherently suffers from topological conflicts at complex intersections, 
 * manifesting as jarring structural artifacts, "bubbles," and "spurs." 
 * 
 * MMPX Advanced introduces comprehensive morphological analysis, utilizing a 
 * vast array of high-precision conditional predicates to expand the 
 * architectural logic by an order of magnitude. Through exhaustive conflict-
 * scenario analysis and granular edge-case resolution, this refinement 
 * completely eliminates morphological glitches. 
 * 
 * Furthermore, the integration of approximate pixel-matching logic effectively 
 * addresses unmapped topological configurations overlooked by the baseline 
 * specification, thereby delivering flawless detail reconstruction while 
 * preserving the authentic pixel-art aesthetic.

 * License: MIT
 * Copyright (c) 2025-2026 by crashGG.
 * ========================================================================= */

/* A texel by its raw 16-bit value stands for the reference's packed
   RGBA8: both are injective on the colours a texel can hold and zero only
   for a hole, so equality and `!= 0` agree. The colour is rebuilt from the
   same raw value as `ps1_src_rgba` does, to fetch each texel once. */
inline float4 ps1_mmpxa_rgba(uint t) {
	if (t == 0u) return float4(0.0);
	return float4(float3(float(t & 0x1Fu), float((t >> 5) & 0x1Fu), float((t >> 10) & 0x1Fu)) / 31.0,
	              (t & 0x8000u) != 0u ? 1.0 : 0.0);
}

inline uint ps1_mmpxa_raw(thread const Ps1TexSrc& tex, int u, int v) {
	return ps1_src_inside(tex, u, v) ? uint(ps1_src_raw(tex, u, v)) : 0u;
}

/* A sample outside the primitive's limits is a hole, not a clamped neighbour. */
#define src(xoffs,yoffs) ps1_mmpxa_raw(tex, bcoords.x + (xoffs), bcoords.y + (yoffs))

#define eq(a,b) (a==b)

#define neq(a,b) (a!=b)

#define all_eq2(a, b1, b2) \
	( eq(a,b1) && eq(a,b2))

#define all_eq3(a, b1, b2, b3) \
	( eq(a,b1) && eq(a,b2) && eq(a,b3))

#define all_eq4(a, b1, b2, b3, b4) \
	( eq(a,b1) && eq(a,b2) && eq(a,b3) && eq(a,b4))

#define any_eq2(a, b1, b2) (eq(a,b1)||eq(a,b2))
#define any_eq3(a, b1, b2, b3) (eq(a,b1)||eq(a,b2)||eq(a,b3))
#define none_eq2(a, b1, b2) !any_eq2(a, b1, b2)

#define slopOFF float4(2.0, 2.0, 2.0, 2.0)
#define slopeBAD float4(4.0, 4.0, 4.0, 4.0)
#define theEXIT float4(8.0, 8.0, 8.0, 8.0)

#define mixXE mix(vX,vE,mixFactor)
#define mixXEoff mixXE+slopOFF
#define Xoff vX+slopOFF

#define checkblack(col) all((col).rgb < float3(0.1, 0.078, 0.1))
#define checkwhite(col) all((col).rgb > float3(0.92, 0.92, 0.92))

#define En4square En3&&eq(E,I)


//RGB visual weight + alpha bias
inline float ps1_mmpxa_luma(float4 col) {

	//Use CRT-era BT.601 standard. Clamp range to [0.0 - 0.999]
    return min(dot(col.rgb, float3(0.299, 0.587, 0.114)), 0.999);
}

/* Constant Descriptions:
 * 0.145898    : (~0.382) ^2
 * 0.8541      : 1.0 -(~0.382) ^2
 * 0.0638587   : (RGB Euclidean distance scaled by ~0.382 twice) ^2
 * 0.75        : (RGB Euclidean distance scaled by  0.500) ^2
 */

// duck calculation: dot(diff,diff) directly incorporates alpha channel  //duck.alpha
// Note: Transparent duck pixels are determined outside sim and mixFactor functions

inline bool ps1_mmpxa_simb(float4 col1, float4 col2) {

	float4 diff = col1 - col2;

	// RGB color difference range (max_diff - min_diff)
	float delta_range = max(diff.r, max(diff.g, diff.b)) - min(diff.r, min(diff.g, diff.b));

	float dot_diff = dot(diff, diff);

	// Equivalent to (delta_range / 0.145898 )^2
	float factor = (delta_range * delta_range) * 46.9787;

	return dot_diff < mix(0.0638587, 0.0, factor);
}

inline bool ps1_mmpxa_sim(float4 col1, float4 col2) {

	float4 diff = col1 - col2;

	float delta_range = max(diff.r, max(diff.g, diff.b)) - min(diff.r, min(diff.g, diff.b));

	float dot_diff = dot(diff, diff);

	// Equivalent to (delta_range / 0.382 )^2
	float factor = (delta_range * delta_range) * 6.8541;

	return dot_diff < mix(0.0638587, 0.0, factor);
}

inline float ps1_mmpxa_mixGate(float4 col1, float4 col2) {

	float4 diff = col1 - col2;

	float delta_range = max(diff.r, max(diff.g, diff.b)) - min(diff.r, min(diff.g, diff.b));

	float dot_diff = dot(diff, diff);

	// Equivalent to (delta_range / 0.618 )^2
	float factor = (delta_range * delta_range) * 2.618034;

	return step(dot_diff, mix(0.75, 0.0, factor));
}


inline float4 ps1_mmpxa_admixC(float4 vX, float4 vE) {

	float mixFactor = ps1_mmpxa_mixGate(vX, vE) * (-0.381966) + 1.0;

	return mixXE;
}

inline float4 ps1_mmpxa_admixK(float4 vX, float4 vE) {

    float4 diff = vX - vE;

	float mixFactor = dot(diff.rgb, diff.rgb) * 0.16666 + 0.5;	// xxx.alpha

	return mixXE;
}

inline float4 ps1_mmpxa_admixL(float4 vE, float4 vX) {

	float mixFactor = 0.381966 * ps1_mmpxa_mixGate(vX,vE) * step(0.002,vE.r+vE.g+vE.b+vE.a); // xxx.alpha.duck

    return mixXE;
}

//**************************************************************************************************************************************
//* 												main slope + X cross-processing mechanism						                *
//******************************************************************************************************************************** zz  *
inline float4 ps1_mmpxa_admixX( uint A, uint B, uint C, uint D, uint E, uint F, uint G, uint H, uint I
		  , uint P, uint PA, uint PC, uint Q, uint QA, uint QG, uint R, uint RC, uint RI, uint S, uint SG, uint SI, uint AA, uint CC, uint GG
		  , float El, float Bl, float Dl, float Fl, float Hl
		  , float4 vE, float4 vB, float4 vD, float4 vC, float4 vG
		  ) {


	bool eq_B_C = eq(B,C);
	bool eq_D_G = eq(D,G);

    if (eq_B_C && eq_D_G) return slopeBAD;


	//Pre-declare
	bool eq_B_P;		bool eq_B_PA;		bool eq_B_PC;
	bool eq_D_Q;		bool eq_D_QA;		bool eq_D_QG;
	bool eq_E_F;		bool eq_E_H;		bool eq_A_AA;

	float4 vX;
	float mixFactor;

	bool eq_E_C = eq(E,C);
	bool eq_E_G = eq(E,G);
    bool eq_A_P = eq(A,P);
    bool eq_A_Q = eq(A,Q);
    bool comboE3 = eq_E_C && eq_E_G;
    bool comboA3 = eq_A_P && eq_A_Q;

	// remove the alpha weighting first ,to avoid jagged edges when E is fully transparent and interacts with black and gray.
	// xxx.alpha.duck
	Bl = fract(Bl);
	Dl = fract(Dl);
	El = fract(El);
	Fl = fract(Fl);
	Hl = fract(Hl);

//* =========================================
//*                    B != D
//* ==================================== zz =
if (neq(B,D)){

	if (eq(E,A)) return slopeBAD;

	float diffBD = abs(Bl-Dl);
	if (diffBD > El-Bl || diffBD > El-Dl) return slopeBAD;


	vX = mix(vB, vD, 0.5);

	mixFactor = 0.381966 * ps1_mmpxa_mixGate(vX,vE) * float(E!=0u);

	eq_B_PC = eq(B,PC);
	eq_D_QG = eq(D,QG);
 
    if (none_eq2(A,B,D)){
		if (comboA3) return mixXEoff;
		if ( eq_A_P && eq_B_PC && !eq_B_C ) return mixXEoff;
		if ( eq_A_Q && eq_D_QG && !eq_D_G ) return mixXEoff;

		if ( eq_A_P && eq_E_G ) return mixXEoff;
		if ( eq_A_Q && eq_E_C ) return mixXEoff;

		if ( eq_E_C && eq_D_G ) return mixXEoff;
		if ( eq_E_G && eq_B_C ) return mixXEoff;

}
    if ( comboE3 ) return mixXEoff;

    if ( eq_E_C && eq_B_PC && neq(B,P)) return mixXEoff;
	if ( eq_E_G && eq_D_QG && neq(D,Q)) return mixXEoff;

	eq_E_F = eq(E,F);

	if (eq(F,H)) {

		if ( eq_E_C && !eq_D_G && (!eq_E_F||neq(E,P)) ) return mixXEoff;
		if ( eq_E_G && !eq_B_C && (!eq_E_F||neq(E,Q)) ) return mixXEoff;

		if ( !eq_E_F && eq_B_PC && eq(F,RC) ) return mixXEoff;
		if ( !eq_E_F && eq_D_QG && eq(H,SG) ) return mixXEoff;
	}

    return slopeBAD;
} //* B != D


						//*********  B == D  *********

	bool Xisblack = checkblack(vB);
	if ( Xisblack && El >0.5 && (Fl<0.078 || Hl<0.078) ) return theEXIT;

	vX = vB;

	mixFactor = 0.381966 * ps1_mmpxa_mixGate(vX,vE) * float(E!=0u);

	bool B_slope;	bool B_tower;	bool B_wall;
    bool D_slope;	bool D_tower;	bool D_wall;
	bool En3;

//* ===================================================
//*                   E - A  x cross
//* =========================================== zz ====
if (eq(E,A)) {


	eq_E_F = eq(E,F);
	eq_E_H = eq(E,H);

	bool Eisblack = checkblack(vE);

    if ( comboE3 && !eq_E_F && !eq_E_H && eq(E,I) ) {

		if (Eisblack) return theEXIT;
		mixFactor = 0.618034 * (1.0 - mixFactor);
		return mixXEoff;
	}

	eq_A_AA = eq(A,AA);

    if ( comboA3 && eq_A_AA && none_eq2(A,PA,QA) )  {
		if (Eisblack) return theEXIT;
		mixFactor = 0.618034 * (1.0 - mixFactor);
		if ( neq(B,PA) && eq(PA,QA) ) return mixXEoff;
		mixFactor += 0.236068;
		return mixXEoff;
	}

    eq_B_PC = eq(B,PC);
    eq_B_PA = eq(B,PA);
    eq_D_QG = eq(D,QG);
    eq_D_QA = eq(D,QA);


	if ( comboE3 && comboA3 &&
		(eq_B_PC || eq_D_QG) && eq_D_QA && eq_B_PA) {
		mixFactor = mixFactor * (-0.618034) + 0.8541;
		mixFactor = max(mixFactor, float(E==0u));	// xxx.alpha.duck
        return mixXEoff;
	}


	if ( comboE3 && eq_A_P
		 && eq_B_PA && eq_D_QA && eq_D_QG
		 && eq_E_H
		) {
		mixFactor = mixFactor * (-0.618034) + 0.8541;
		mixFactor = max(mixFactor, float(E==0u));	// xxx.alpha.duck
        return mixXEoff;
		}

	if ( comboE3 && eq_A_Q
		 && eq_B_PA && eq_D_QA && eq_B_PC
		 && eq_E_F
		) {
		mixFactor = mixFactor * (-0.618034) + 0.8541;
		mixFactor = max(mixFactor, float(E==0u));	// xxx.alpha.duck
        return mixXEoff;
		}


	if (comboA3) return Xoff;

    if (comboE3) return mixXEoff;

	eq_B_P = eq(B, P);
	eq_D_Q = eq(D, Q);

	B_slope = eq_B_PC && !eq_B_P && !eq_B_C && !eq_B_PA;
	D_slope = eq_D_QG && !eq_D_Q && !eq_D_G && !eq_D_QA;

	B_wall = eq_B_C && !eq_B_PC && !eq_B_P;
	D_wall = eq_D_G && !eq_D_QG && !eq_D_Q;
	
	B_tower = eq_B_P && !eq_B_PC && !eq_B_C && !eq_B_PA;
	D_tower = eq_D_Q && !eq_D_QG && !eq_D_G && !eq_D_QA;

	if ( B_slope && eq_E_G ) return mixXEoff;
	if ( D_slope && eq_E_C ) return mixXEoff;


//* E B D Region Checkerboard Scoring Rule

    float scoreE = 0.0; float scoreB = 0.0; float scoreD = 0.0; float scoreZ = 0.0;

//*	E Zone
    if (eq_E_C) {
		scoreE += 1.0 +float(eq(F,H)) +float(B_slope);
		scoreE -= float(all_eq2(E,P,PC)&&!D_wall);
	}

    if (eq_E_G) {
        scoreE += 1.0 +float(eq(F,H)) +float(D_slope);
		scoreE -= float(all_eq2(E,Q,QG)&&!B_wall);
    }

	scoreE += float(B_slope && eq_A_Q || D_slope && eq_A_P);

    En3 = eq_E_F && eq_E_H;

	if ( scoreE<0.01 && mixFactor<0.01 && En4square && eq(E,S)==eq(E,SI) && eq(E,R)==eq(E,RI) ) return theEXIT;


	if ( scoreE<0.01 && !En3 && neq(E,I) ) {
		if ( B_wall && eq_E_F ) return theEXIT;
		if ( D_wall && eq_E_H ) return theEXIT;
    }

	if (E==0u && !Xisblack) return vX;	// xxx.alpha.duck

	scoreE += float(B_slope && eq_A_P || D_slope && eq_A_Q);

    if ( !En3 && eq(F,H) ) {
		if (Eisblack) return slopeBAD;

		bool condZ1 = B_wall && (eq(F,R) || eq(F,RC) || eq(G,H) || eq(F,I));
		bool condZ2 = D_wall && (eq(C,F) || eq(H,SG) || eq(H,S) || eq(F,I));
		scoreZ = float(condZ1 || condZ2);
    }


//*	B Zone

    if (eq_B_PA) {
		scoreB -= 1.0 +float(eq(P,C)) +float(eq_A_AA);
	}

	if (eq(P,C)){
		scoreB -= float(eq_A_AA);
		scoreZ *= float(scoreE < 0.01);
	}

//*  D Zone

    if (eq_D_QA) {
		scoreD -= 1.0 +float(eq(G,Q)) +float(eq_A_AA);
	}

	if (eq(G,Q)){
		scoreD -= float(eq_A_AA);
		scoreZ *= float(scoreE < 0.01);
	}

    float scoreFinal = scoreE + scoreB + scoreD + scoreZ ;

	scoreFinal += float(min(scoreB,scoreD) > -0.01 && (B_wall && D_tower || B_tower && D_wall)) *2.0;

	mixFactor *= (1.0 - step(1.99, scoreFinal));
	return mixXE + slopeBAD*(1.0 - step(0.99, scoreFinal));

}	//* E == A


//* ===============================================
//*              	E - C - G     main rules
//* ========================================= zz ==

    if (eq_E_C ) {
		if (comboA3) return vX;
		if (comboE3) return mixXE;
		if (all_eq2(B,A,PA) && all_eq3(E,F,P,PC)) return theEXIT;
		return mixXE;
	}

	if (eq_E_G) {
		if (comboA3) return vX;
		if (comboE3) return mixXE;
		if (all_eq2(D,A,QA) && all_eq3(E,H,Q,QG)) return theEXIT;
		return mixXE;
	}

	if (E==0u) return theEXIT;		// xxx.alpha

//* =======================================================
//*                  F - H / B+ D+ Extended Rules
//* ================================================= zz ==


    bool eq_A_B = eq(A,B);
    bool eq_F_H = eq(F,H);

	eq_B_P  = eq(B,P);
	eq_B_PC = eq(B,PC);
	eq_B_PA = eq(B,PA);
	eq_D_Q  = eq(D,Q);
	eq_D_QG = eq(D,QG);
	eq_D_QA = eq(D,QA);

	B_slope = eq_B_PC && !eq_B_P && !eq_B_C;
	D_slope = eq_D_QG && !eq_D_Q && !eq_D_G;
	B_tower = eq_B_P && !eq_B_PC && !eq_B_C && !eq_B_PA;
	D_tower = eq_D_Q && !eq_D_QG && !eq_D_G && !eq_D_QA;
	B_wall = eq_B_C && !eq_B_PC && !eq_B_P;
	D_wall = eq_D_G && !eq_D_QG && !eq_D_Q;


    if (!eq_A_B) {

        if (comboA3) return Xoff;

        if ( (B_slope||B_tower) && (D_slope||D_tower) ) return Xoff;

        if ( B_slope && eq_A_P ) return mixXEoff;
        if ( D_slope && eq_A_Q ) return mixXEoff;

        if ( (B_slope || D_slope) && eq_F_H ) return mixXEoff;

        if ( B_slope && eq(H,SG) ) return mixXEoff;
        if ( D_slope && eq(F,RC) ) return mixXEoff;

        if ( B_slope && eq_A_Q && eq(Q,QG) ) return mixXEoff;
        if ( D_slope && eq_A_P && eq(P,PC) ) return mixXEoff;

    }

	bool sim_EC = E!=0u && C!=0u && ps1_mmpxa_sim(vE, vC);	// xxx.alpha.duck
	bool sim_EG = E!=0u && G!=0u && ps1_mmpxa_sim(vE, vG);	// xxx.alpha.duck

	float E_lumDiff = mix(0.381966, 0.145898, max((El - 0.8541),0.0) * 6.8541);

    if ( mixFactor<0.01 && !sim_EC && !sim_EG && neq(E,I) && abs(El-Fl)>E_lumDiff && abs(El-Hl)>E_lumDiff ) return slopeBAD;


	eq_E_F = eq(E,F);
	eq_E_H = eq(E,H);

	if ( eq_B_C && eq_D_Q ) {
		if ( eq(P,PC) && eq(A,QA) && !eq_D_QG && eq_E_F && !eq_E_H && eq(H,I)) return theEXIT;
		if ( eq_A_B ) return slopeBAD;
		if ( B_wall && D_tower && eq_E_F) return vX;
		return mixXEoff;
	}

	if ( eq(D,G) && eq(B,P)) {
		if ( eq(Q,QG) && eq(A,PA) && !eq_B_PC && eq_E_H && !eq_E_F && eq(F,I)) return theEXIT;
		if ( eq_A_B ) return slopeBAD;
		if ( B_tower && D_wall && eq_E_H) return vX;
		return mixXEoff;
	}


    En3 = eq_E_F && eq_E_H;

	if ( En4square ) {
        if ( ( eq_B_C || eq_D_G) && eq_A_B) return theEXIT;
        if ( ( eq_B_C || eq_D_G || mixFactor<0.01) && (eq(E,S) == eq(E, SI) && eq(E,R) == eq(E, RI)) ) return theEXIT;
        return mixXEoff;
    }

	if (!eq_B_C && !eq_D_G ) {
		if ( comboA3 && eq_F_H ) return Xoff;

		if ( comboA3&&eq_B_PC&&eq(C,CC) ) return Xoff;
		if ( comboA3&&eq_D_QG&&eq(G,GG) ) return Xoff;

		if ( !eq_B_P && !eq_B_PC && !eq_D_Q && !eq_D_QG && !En3 ) return slopeBAD;

		if (eq_A_Q&&sim_EC) return mixXEoff;
		if (eq_A_P&&sim_EG) return mixXEoff;
		if (sim_EC&&sim_EG ) return mixXEoff;
	}

 	if ( En3 && eq_A_B) return theEXIT;

	if (eq_F_H) {

		if ( eq_B_PC&&eq(F,RC) || eq_D_QG&&eq(H,SG) ) return mixXEoff;

		if (eq_A_B) return slopeBAD;

		if ( eq_B_C || eq_D_G) return mixXEoff;
		if ( eq_B_PC || eq_D_QG) return mixXEoff;

	}

	return slopeBAD;

}	//* admixX


inline float4 ps1_mmpxa_admixS( uint A, uint B, uint C, uint D, uint E, uint F, uint G, uint H, uint I
		   , uint R, uint RC, uint RI, uint S, uint SG, uint SI, uint II, uint CC
		   , float4 vE, float4 vF, float4 vC
		   ) {



    if (any_eq2(F,C,I)) return vE;

	if ( (eq(F,RI) || eq(G,S) || eq(R, RI)) && neq(R,I) ) return vE;

    if (eq(H, S) && none_eq2(H,I,SG)) return vE;

    if ( eq(R, RC) || eq(G,SG) ) return vE;

	if ( checkwhite(vE) && all_eq2(E,C,D) && none_eq2(E,RC,CC)) return vE;


	float4 vX = vF;
	float mixFactor = 0.381966 * ps1_mmpxa_mixGate(vX,vE) * float(E!=0);	// xxx.alpha.duck

	if ( eq(E,C) && (eq(E,D)||eq(B,D)) ) return mixXE;

	bool sim_E_C = E!=0u && E!=0u && ps1_mmpxa_sim(vE,vC);	// xxx.alpha.duck

	if ( sim_E_C && eq(E,D) && eq(B,C) ) return mixXE;

	if ( (sim_E_C || mixFactor>0.01) && all_eq2(B,C,D) ) return mixXE;

    return vE;
}

inline Ps1Filtered ps1_filter_mmpx_advanced(thread const Ps1TexSrc& tex, float2 coords) {

	int2 bcoords = int2(floor(coords));

	uint E = uint(ps1_src_raw(tex, bcoords.x, bcoords.y));
	float4 vE = ps1_mmpxa_rgba(E);

	uint B = src(0, -1);
	uint D = src(-1, 0);
	uint F = src(+1, 0);
	uint H = src(0, +1);
	float4 vB = ps1_mmpxa_rgba(B);
	float4 vD = ps1_mmpxa_rgba(D);
	float4 vF = ps1_mmpxa_rgba(F);
	float4 vH = ps1_mmpxa_rgba(H);

	float4 texcol;
	float ialpha;

	// default pixel
	ialpha = float(E != 0u);
	texcol = vE;

    bool eq_E_D = eq(E,D);
    bool eq_E_F = eq(E,F);
    bool eq_E_B = eq(E,B);
    bool eq_E_H = eq(E,H);
    bool eq_B_H = eq(B,H);
    bool eq_D_F = eq(D,F);

//* Skip processing for horizontal/vertical 3-pixel identical & mirror symmetric patterns
bool skiprest = (eq_E_D && eq_E_F) || (eq_E_B && eq_E_H) || (eq_B_H && eq_D_F);
if (!skiprest) {



    // 5x5
	uint A = src(-1, -1);
	uint C = src(+1, -1);
	uint G = src(-1, +1);
	uint I = src(+1, +1);
	float4 vA = ps1_mmpxa_rgba(A);
	float4 vC = ps1_mmpxa_rgba(C);
	float4 vG = ps1_mmpxa_rgba(G);
	float4 vI = ps1_mmpxa_rgba(I);

	uint P  = src(0, -2);
	uint Q  = src(-2, 0);
	uint R  = src(+2, 0);
	uint S  = src(0, +2);

	uint PA = src(-1, -2);
	uint PC = src(+1, -2);
	uint QA = src(-2, -1);
	uint QG = src(-2, +1); //*             AA   PA   [P]  PC   CC
	uint RC = src(+2, -1); //*               -|----|----|----|-
	uint RI = src(+2, +1); //*             QA |  A |  B | C  | RC
	uint SG = src(-1, +2); //*               -|----|----|----|-
	uint SI = src(+1, +2); //*            [Q] |  D |  E | F  | [R]
	uint AA = src(-2, -2); //*               -|----|----|----|-
	uint CC = src(+2, -2); //*             QG |  G |  H | I  | RI
	uint GG = src(-2, +2); //*               -|----|----|----|-
	uint II = src(+2, +2); //*             GG   SG   [S]  SI   II


    float4 J = vE;    float4 K = vE;    float4 L = vE;    float4 M = vE;


	//*	pre-cal
    float Bl = ps1_mmpxa_luma(vB) + float(B==0u);
    float Dl = ps1_mmpxa_luma(vD) + float(D==0u);
    float El = ps1_mmpxa_luma(vE) + float(E==0u);
    float Fl = ps1_mmpxa_luma(vF) + float(F==0u);
    float Hl = ps1_mmpxa_luma(vH) + float(H==0u);

    bool eq_B_D = eq(B,D);
    bool eq_B_F = eq(B,F);
    bool eq_D_H = eq(D,H);
    bool eq_F_H = eq(F,H);


    bool oppoPix =  eq_B_H || eq_D_F;

    bool slope1 = false;    bool slope2 = false;    bool slope3 = false;    bool slope4 = false;

    bool slope1ok = false;  bool slope2ok = false;  bool slope3ok = false;  bool slope4ok = false;
    bool slope1end = false;  bool slope2end = false;  bool slope3end = false;  bool slope4end = false;


// B - D
	if ( (B!=0u && D!=0u) && // xxx.alpha
		(!eq_E_B && !eq_E_D && !oppoPix) && (!eq_D_H && !eq_B_F)
	 && (eq(E,A) || El>=Dl&&El>=Bl) && ( (El<Dl&&El<Bl) || none_eq2(A,B,D) || neq(E,P) || neq(E,Q) )
	 && ( eq_B_D &&(eq(E,A)||eq(B,PC)||eq(D,QG)||ps1_mmpxa_sim(vE,vC)||ps1_mmpxa_sim(vE,vG)) || ps1_mmpxa_simb(vB,vD)&&(eq_F_H||eq(E,C)||eq(E,G)) )
		) {
		J=ps1_mmpxa_admixX(A,B,C,D,E,F,G,H,I
				,P,PA,PC,Q,QA,QG,R,RC,RI,S,SG,SI,AA,CC,GG
				,El, Bl, Dl, Fl, Hl
				,vE, vB, vD, vC, vG
				);
		slope1 = true;
		slope1ok = (J.b < 1.1);
		slope1end = (J.b < 3.1);
		skiprest = (J.b > 7.1);
		J = (J.b > 3.1) ? vE :
			(J.b > 1.1) ? (J - 2.0) :
			J;
	}
// B - F
	if ( !slope1 && (B!=0u && F!=0u)
	 && (!eq_E_B && !eq_E_F && !oppoPix) && (!eq_B_D && !eq_F_H)
	 && (eq(E,C) || El>=Bl&&El>=Fl) && ( (El<Bl&&El<Fl) || none_eq2(C,B,F) || neq(E,P) || neq(E,R) )
	 && ( eq_B_F &&(eq(E,C)||eq(B,PA)||eq(F,RI)||ps1_mmpxa_sim(vE,vA)||ps1_mmpxa_sim(vE,vI)) || ps1_mmpxa_simb(vB,vF)&&(eq_D_H||eq(E,A)||eq(E,I)) )
	 ) {
		K=ps1_mmpxa_admixX(C,F,I,B,E,H,A,D,G
				,R,RC,RI,P,PC,PA,S,SI,SG,Q,QA,QG,CC,II,AA
				,El,Fl,Bl,Hl,Dl
				,vE,vF,vB,vI,vA
				);
		slope2 = true;
		slope2ok = (K.b < 1.1);
		slope2end = (K.b < 3.1);
		skiprest = (K.b > 7.1);
		K = (K.b > 3.1) ? vE :
			(K.b > 1.1) ? (K - 2.0) :
			K;
	}
// D - H
	if ( !slope1 && !skiprest && (D!=0u && H!=0u)
	 && (!eq_E_D && !eq_E_H && !oppoPix) && (!eq_F_H && !eq_B_D)
	 && (eq(E,G) || El>=Hl&&El>=Dl)  &&  ((El<Hl&&El<Dl) || none_eq2(G,D,H) || neq(E,S) || neq(E,Q))
	 &&	( eq_D_H &&(eq(E,G)||eq(D,QA)||eq(H,SI)||ps1_mmpxa_sim(vE,vA)||ps1_mmpxa_sim(vE,vI)) || ps1_mmpxa_simb(vD,vH)&&(eq_B_F||eq(E,A)||eq(E,I)) )
	 ) {
		L=ps1_mmpxa_admixX(G,D,A,H,E,B,I,F,C
				,Q,QG,QA,S,SG,SI,P,PA,PC,R,RI,RC,GG,AA,II
				,El,Dl,Hl,Bl,Fl
				,vE,vD,vH,vA,vI
				);
		slope3 = true;
		slope3ok = (L.b < 1.1);
		slope3end = (L.b < 3.1);
		skiprest = (L.b > 7.1);
		L = (L.b > 3.1) ? vE :
			(L.b > 1.1) ? (L - 2.0) :
			L;
	}
// F - H
	if ( !slope2 && !slope3 && !skiprest && (F!=0u && H!=0u)
	 && (!eq_E_F && !eq_E_H && !oppoPix) && (!eq_B_F && !eq_D_H)
	 && (eq(E,I) || El>=Fl&&El>=Hl)  &&  ((El<Fl&&El<Hl) || none_eq2(I,F,H) || neq(E,R) || neq(E,S))
	 && ( eq_F_H &&(eq(E,I)||eq(F,RC)||eq(H,SG)||ps1_mmpxa_sim(vE,vC)||ps1_mmpxa_sim(vE,vG)) || ps1_mmpxa_simb(vF,vH)&&(eq_B_D||eq(E,C)||eq(E,G)) )
	  ) {
		M=ps1_mmpxa_admixX(I,H,G,F,E,D,C,B,A
				,S,SI,SG,R,RI,RC,Q,QG,QA,P,PC,PA,II,GG,CC
				,El,Hl,Fl,Dl,Bl
				,vE,vH,vF,vG,vC
				);
		slope4 = true;
		slope4ok = (M.b < 1.1);
		slope4end = (M.b < 3.1);
		skiprest = (M.b > 7.1);
		M = (M.b > 3.1) ? vE :
			(M.b > 1.1) ? (M - 2.0) :
			M;
	}

//* =========================  2:1 long stepped slope  =========================

	if (slope4ok) {
		if (all_eq2(R,F,G) && neq(R, RC) && (neq(Q,G)||eq(Q, QA))) {L=ps1_mmpxa_admixL(vE,vH); skiprest = true;}
		if (all_eq2(S,H,C) && neq(S, SG) && (neq(P,C)||eq(P, PA))) {K=ps1_mmpxa_admixL(vE,vF); skiprest = true;}
	}

	if (slope3ok) {
		if (all_eq2(Q,D,I) && neq(Q, QA) && (neq(R,I)||eq(R, RC))) {M=ps1_mmpxa_admixL(vE,vH); skiprest = true;}
		if (all_eq2(S,H,A) && neq(S, SI) && (neq(A,P)||eq(P, PC))) {J=ps1_mmpxa_admixL(vE,vD); skiprest = true;}
	}

	if (slope2ok) {
		if (all_eq2(R,F,A) && neq(R, RI) && (neq(A,Q)||eq(Q, QG))) {J=ps1_mmpxa_admixL(vE,vB); skiprest = true;}
		if (all_eq2(P,B,I) && neq(P, PA) && (neq(I,S)||eq(S, SG))) {M=ps1_mmpxa_admixL(vE,vF); skiprest = true;}
	}

	if (slope1ok) {
		if (all_eq2(Q,D,C) && neq(Q, QG) && (neq(C,R)||eq(R, RI))) {K=ps1_mmpxa_admixL(vE,vB); skiprest = true;}
		if (all_eq2(P,B,G) && neq(P, PC) && (neq(G,S)||eq(S, SI))) {L=ps1_mmpxa_admixL(vE,vD); skiprest = true;}
	}



//* =========================  2:1 staggered slope  (new rule)  ===========================

if (!skiprest && !oppoPix) {


    if (!eq_E_H && none_eq2(H,A,C)) {

        if ( (!slope2 && !eq_B_F) && (!slope3 && !eq_D_H) && (!slope4end && !eq_F_H) && F!=0u &&
            !eq_E_F && eq(R,H) && eq(F,G) ) {
            M = ps1_mmpxa_admixS( A, B, C, D, E, F, G, H, I
                      , R, RC, RI, S, SG, SI, II, CC
                      , vE, vF, vC
                      );
            skiprest = true;}

        if ( !skiprest && (!slope1 && !eq_B_D) && (!slope4 && !eq_F_H) && (!slope3end && !eq_D_H) && D!=0u &&
             !eq_E_D && eq(Q,H) && eq(D,I) ) {
            L = ps1_mmpxa_admixS( C, B, A, F, E, D, I, H, G
                      , Q, QA, QG, S, SI, SG, GG, AA
                      , vE, vD, vA
                      );
            skiprest = true;}
    }

    if ( !skiprest && !eq_E_B && none_eq2(B,G,I)) {

        if ( (!slope1 && !eq_B_D)  && (!slope4 && !eq_F_H) && (!slope2end && !eq_B_F) && F!=0u &&
              !eq_E_F && eq(B,R) && eq(A,F) ) {
            K = ps1_mmpxa_admixS( G, H, I, D, E, F, A, B, C
                      , R, RI, RC, P, PA, PC, CC, II
                      , vE, vF, vI
                      );
            skiprest = true;}

        if ( !skiprest && (!slope2 && !eq_B_F) && (!slope3 && !eq_D_H) && (!slope1end && !eq_B_D) && D!=0u &&
             !eq_E_D && eq(B,Q) && eq(C,D) ) {
            J = ps1_mmpxa_admixS( I, H, G, F, E, D, C, B, A
                      , Q, QG, QA, P, PC, PA, AA, GG
                      , vE, vD, vG
                      );
            skiprest = true;}

    }


    if ( !skiprest && !eq_E_D && none_eq2(D,C,I) ) {

        if ( (!slope1 && !eq_B_D) && (!slope4 && !eq_F_H) && (!slope3end && !eq_D_H) && H!=0u &&
              !eq_E_H && eq(D,S) && eq(A,H) ) {
            L = ps1_mmpxa_admixS( C, F, I, B, E, H, A, D, G
                      , S, SI, SG, Q, QA, QG, GG, II
                      , vE, vH, vI
                      );
            skiprest = true;}

        if ( !skiprest && (!slope3 && !eq_D_H) && (!slope2 && !eq_B_F) && (!slope1end && !eq_B_D) && B!=0u &&
              !eq_E_B && eq(P,D) && eq(B,G) ) {
            J = ps1_mmpxa_admixS( I, F, C, H, E, B, G, D, A
                      , P, PC, PA, Q, QG, QA, AA, CC
                      , vE, vB, vC
                      );
            skiprest = true;}

    }

    if ( !skiprest && !eq_E_F && none_eq2(F,A,G) ) {

        if ( (!slope2 && !eq_B_F) && (!slope3 && !eq_D_H) && (!slope4end && !eq_F_H) && H!=0u &&
              !eq_E_H && eq(S,F) && eq(H,C) ) {
            M = ps1_mmpxa_admixS( A, D, G, B, E, H, C, F, I
                      , S, SG, SI, R, RC, RI, II, GG
                      , vE, vH, vG
                      );
            skiprest = true;}

        if ( !skiprest && (!slope1 && !eq_B_D) && (!slope4 && !eq_F_H) && (!slope2end && !eq_B_F) && B!=0u &&
             !eq_E_B && eq(P,F) && eq(B,I) ) {
            K = ps1_mmpxa_admixS( G, D, A, H, E, B, I, F, C
                      , P, PA, PC, R, RI, RC, CC, AA
                      , vE, vB, vA
                      );
            skiprest = true;}

    }
}

skiprest = skiprest||slope1||slope2||slope3||slope4||E==0u||B==0u||D==0u||F==0u||H==0u;

//* =================== Concave+Cross pattern (P100) =================

float4 vT;		float maxl;
 //* top [B]
if (!skiprest &&
    Bl<El && !eq_E_D && !eq_E_F && eq_E_H && none_eq2(E,A,C) && all_eq3(E,G,I,S) ) {

	float B1 = float(eq(B, A));
	float B2 = float(eq(B, C));
	float DD = float(eq(A, D));
	float FF = float(eq(C, F));

	float sideFactor = eq_D_F && DD!=FF ? 1.0 : -0.145898;
	Bl = Bl - (B1 +B2 +B1*B2) *0.381966;
	Dl = Dl - step(El, Dl) + DD*sideFactor;
	Fl = Fl - step(El, Fl) + FF*sideFactor;

	maxl = max(Bl, max(Dl, Fl));

	vT = eq_B_D || eq_B_F ? vB :
		 maxl <= Dl      ? vD :
		 maxl <= Fl      ? vF :
						   vB ;
	vT = ps1_mmpxa_admixC(vT,vE);

	bool nolink = !eq_D_F && (DD==0.0) && (FF==0.0);
	J = Dl<0.0&&nolink ? vE : vT;
    K = Fl<0.0&&nolink ? vE : vT;
	L = mix(vE, J, 0.381966*float(eq_D_F));
	M = L;

   skiprest = true;
}
 //* bottom (H)
if (!skiprest &&
    Hl<El && !eq_E_D && !eq_E_F && eq_E_B && none_eq2(E,G,I) && all_eq3(E,A,C,P) ) {

	float H1 = float(eq(H, G));
	float H2 = float(eq(H, I));
	float DD = float(eq(D, G));
	float FF = float(eq(F, I));

	float sideFactor = eq_D_F && DD!=FF ? 1.0 : -0.145898;

	Hl = Hl - (H1+H2+H1*H2) *0.381966;
	Dl = Dl - step(El, Dl) + DD*sideFactor;
	Fl = Fl - step(El, Fl) + FF*sideFactor;

	maxl = max(Hl, max(Dl, Fl));

	vT = eq_D_H || eq_F_H ? vH :
		 maxl <= Dl      ? vD :
		 maxl <= Fl      ? vF :
						   vH ;
	vT=ps1_mmpxa_admixC(vT,vE);

	bool nolink = !eq_D_F && (DD==0.0) && (FF==0.0);

	L = Dl<0.0&&nolink ? vE : vT;
    M = Fl<0.0&&nolink ? vE : vT;
	J = mix(vE, L, 0.381966*float(eq_D_F));
	K = J;

   skiprest = true;
}
 //* right [F]
if (!skiprest &&
    Fl<El && !eq_E_B && !eq_E_H && eq_E_D && none_eq2(E,C,I) && all_eq3(E,A,G,Q) ) {

	float F1 = float(eq(F, C));
	float F2 = float(eq(F, I));
	float BB = float(eq(B, C));
	float HH = float(eq(H, I));

	float sideFactor = eq_B_H && BB!=HH ? 1.0 : -0.145898;

	Fl = Fl - (F1+F2+F1*F2) *0.381966;
	Bl = Bl - step(El, Bl) + BB*sideFactor;
	Hl = Hl - step(El, Hl) + HH*sideFactor;

	maxl = max(Fl, max(Bl, Hl));

	vT = eq_B_F || eq_F_H ? vF :
		 maxl <= Bl      ? vB :
		 maxl <= Hl      ? vH :
						   vF ;
	vT=ps1_mmpxa_admixC(vT,vE);

	bool nolink =  !eq_B_H && (BB==0.0) && (HH==0.0);

	K = Bl<0.0&&nolink ? vE : vT;
    M = Hl<0.0&&nolink ? vE : vT;
	J = mix(vE, K, 0.381966*float(eq_B_H));
	L = J;

   skiprest = true;
}
 //* left [D]
if (!skiprest &&
    Dl<El && !eq_E_B && !eq_E_H && eq_E_F && none_eq2(E,A,G) && all_eq3(E,C,I,R) ) {

	float D1 = float(eq(D, A));
	float D2 = float(eq(D, G));
	float BB = float(eq(B, A));
	float HH = float(eq(H, G));

	float sideFactor = eq_B_H && BB!=HH ? 1.0 : -0.145898;

	Dl = Dl - (D1+D2+D1*D2) *0.381966;
	Bl = Bl - step(El, Bl) + BB*sideFactor;
	Hl = Hl - step(El, Hl) + HH*sideFactor;

	maxl = max(Dl, max(Bl, Hl));

	vT = eq_B_D || eq_D_H ? vD :
		 maxl <= Bl      ? vB :
		 maxl <= Hl      ? vH :
						   vD ;
	vT=ps1_mmpxa_admixC(vT,vE);

	bool nolink =  !eq_B_H && (BB==0.0) && (HH==0.0);

	J = Bl<0.0&&nolink ? vE : vT;
    L = Hl<0.0&&nolink ? vE : vT;
	K = mix(vE, J, 0.381966*float(eq_B_H));
	M = K;

   skiprest = true;
}

//* ===================  SKorpion pattern (P99) ==================


if (!skiprest && !eq_E_F&&eq_E_D&&eq_B_F&&eq_F_H && all_eq2(E,C,I) && (eq(E,Q)||El>Fl) && neq(F,src(+3, 0)) ) {K=ps1_mmpxa_admixK(vF,vE); M=K; skiprest=true;}	//* RIGHT
if (!skiprest && !eq_E_D&&eq_E_F&&eq_B_D&&eq_D_H && all_eq2(E,A,G) && (eq(E,R)||El>Dl) && neq(D,src(-3, 0)) ) {J=ps1_mmpxa_admixK(vD,vE); L=J; skiprest=true;}	//* LEFT
if (!skiprest && !eq_E_H&&eq_E_B&&eq_D_H&&eq_F_H && all_eq2(E,G,I) && (eq(E,P)||El>Hl) && neq(H,src(0, +3)) ) {L=ps1_mmpxa_admixK(vH,vE); M=L; skiprest=true;}	//* BOTTOM
if (!skiprest && !eq_E_B&&eq_E_H&&eq_B_D&&eq_B_F && all_eq2(E,A,C) && (eq(E,S)||El>Bl) && neq(B,src(0, -3)) ) {J=ps1_mmpxa_admixK(vB,vE); K=J;}					//* TOP


	//final write
	float2 fpart = fract(coords);

	float4 res = (fpart.x < 0.5) ? ((fpart.y < 0.5) ? J : L) : ((fpart.y < 0.5) ? K : M);

	ialpha = step(0.002, res.r+res.g+res.b+res.a);
	texcol = res;
}

	return ps1_filtered_of(texcol, ialpha);
}

#undef src
#undef eq
#undef neq
#undef all_eq2
#undef all_eq3
#undef all_eq4
#undef any_eq2
#undef any_eq3
#undef none_eq2
#undef slopOFF
#undef slopeBAD
#undef theEXIT
#undef mixXE
#undef mixXEoff
#undef Xoff
#undef checkblack
#undef checkwhite
#undef En4square

#endif /* PS1_FILTER_MMPX_ADVANCED_H */
