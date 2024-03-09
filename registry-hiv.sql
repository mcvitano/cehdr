/* =======================================================================================================================================
Project:		HIV Registry (CEHDR)
Author:			Matt Cvitanovich
Create date:	2024-01-17
Update date:

Description:	
	Identifies patients in the CEHDR HIV_PATIENTS database table as included in HIVCOR (HIV core outcomes registry) or "Excluded".
	The crieria for inclusion is:
		(1) Any of the following:
				- "reactive" HIV antibody 1/2 differentiation test
				- "reactive" HIV antibody confirmation test
				- "detectable" HIV RNA (viral load) test
				- an order for antiretroviral (ARV) medication for treatment of HIV, exluding Truvada and Descovy (PrEP)
	*and*
		(2) RNA test *or* CD4 test (regardless of result)
	*and*
		(3) a completed encounter at Healing Wings, True Worth, or Tarrant County Correctional Facility

	Note:
		- This script does NOT provide dates of entry/eligibility or lab test values (which are date-dependent)
		- Technically, any result from an antiretroviral resistance test indicates HIV(+) status as the test requies
			a minimum viral load in order to run (all other samples will be rejected) ... Unfortunately, until circa 2022
			these test results are not included in the LAB table

Steps:
	(1) Contruct temp table of lab test results using a curated list of component IDs
	(2) Construct temp table of orders for AB differentiation tests that indicate "positive" status in the LAB_COMMENTS table
	(3) Use CTEs to merge requested data fields into the PATIENT table

==========================================================================================
Modification History
------------------------------------------------------------------------------------------
Modify Date		Change Description
==========================================================================================


===========================================================================================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/*
================================================================================================================
										LAB TEST COMPONENT IDs
================================================================================================================

There are additional test components. 
Nevertheless, they are irrelevant given the set below (e.g., log values, text interpretations, etc.)

Query to construct below table:
	SELECT COMPONENT_ID, COMPONENT_NM, MIN(SPECIMN_TAKEN_TIME) as min, MAX(SPECIMN_TAKEN_TIME) as max
	FROM HIV_LABS
	WHERE 1=1
		AND (COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @diff_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @naat_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_abs_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_per_components)
			)
	GROUP BY COMPONENT_ID, COMPONENT_NM;

---------------------------------------------------------------------------------------------------
											IN SERVICE
---------------------------------------------------------------------------------------------------
													~ START		~ END			TEST_TYPE
1234444644	JPS HIV AG/AB, 4TH GEN (REF)			2023-06		(in use)		AB Screen
1230001172	HIV ANTIBODY SCREEN						2021-11		(in use)		AB Screen

1234444746	JPS HIV-1 ANTIBODY (REF)				2023-06		(in use)		AB Differentiation
1234444747	JPS HIV-2 ANTIBODY (REF)				2023-06		(in use)		AB Differentiation
1230001157	HIV-1 ANTIBODY							2021-11		(in use)		AB Differentiation
1230001159	HIV-2 ANTIBODY							2021-11		(in use)		AB Differentiation

1234101169	HIV VIRAL LOAD TARGET NOT DETECTED		2021-11		(in use)		RNA
1230001158	HIV-1 QUALITATIVE						2021-11		(in use)		RNA
1230001163	HIV1 COPIES/ML							2021-11		(in use)		RNA
1230002269	JPS HIV-1 QNT (COPIES/ML)				2021-11		(in use)		RNA
1234444899	JPS HIV-1 PR, RT PROVIRAL DNA (REF)		2021-09		(in use)		RNA (DNA)

1230000594	% CD4									2021-11		(in use)		CD4 %
1230000596	ABSOLUTE CD4							2021-11		(in use)		CD4 absolute

---------------------------------------------------------------------------------------------------
										OUT OF SERVICE
---------------------------------------------------------------------------------------------------
													~ START		~ END			TEST_TYPE
2412		HIV AG/AB, 4TH GEN						2017-02		2021-11			AB Screen
273			HIV ANTIBODY SCREEN						2011-05		2021-11			AB Screen
275			HIV ANTIBODY SCREEN STUDY				2011-05		2021-11			AB Screen
1348		HIV 1-2 ORAQUICK						2013-01		2015-04			AB Screen
1740042		RAPID HIV 1 AND 2						2011-06 	2015-07			AB Screen
1496		OHS RAPID HIV							2013-09		2014-08			AB Screen
30409193	ED HIV-1/2								2011-06		2011-12			AB Screen
587			ED HIV									2011-05		2011-12			AB Screen

2221		HIV-1/2 AB DIFFERENTIATION IMMUNOASSAY	2016-05		2021-11			AB Differentiation
1740031		HIV-1 ANTIBODY							2016-05		2019-09			AB Differentiation
1612903		HIV-2 ANTIBODY							2016-05 	2019-09			AB Differentiation
2222		HIV INTERPRETATION						2016-05		2019-09			AB Differentiation
2005		HIV-1/HIV-2  MULTISPOT RAPID TEST STUDY	2014-12		2016-05			AB Differentiation
1257		HIV 1/2 MULTISPOT						2012-12		2016-05			AB Differentiation

268			HIV NAAT								2011-05		2018-05			AB Confirmatory
1558004		HIV-1 CONFIRMATION						2011-05		2014-10			AB Confirmatory

1510740		HIV1 COPIES/ML							2011-05		2021-11			RNA
1662		HIV-1 QUALITATIVE						2001-04		2021-11			RNA
1497		HIV-1 RNA, QL							2013-12		2019-09			RNA
2269		HIV-1 QNT (COPY/ML)						2016-06		2019-09			RNA
2268		HIV-1 QNT INTERP						2016-06		2019-09			RNA
1561915		HIV-1 RNA BRANCHING DNA					2012-01		2015-07			RNA

1558134		CD4 % HELPER T CELL						2011-05		2021-11			CD4 %
1558135		CD4 T CELL ABSOLUTE						2011-05		2021-11			CD4 absolute

*/


-- Declare lab test components as tables
DECLARE @ab_components table (COMPONENT_ID int)
DECLARE @diff_components table (COMPONENT_ID int)
DECLARE @naat_components table (COMPONENT_ID int)
DECLARE @rna_components table (COMPONENT_ID int)
DECLARE @cd4_abs_components table (COMPONENT_ID int)
DECLARE @cd4_per_components table (COMPONENT_ID int)

-- Set values
INSERT INTO @ab_components VALUES (273), (275), (587), (1348), (1496), (2412), (1740042), (30409193), (1230001172), (1234444644)
INSERT INTO @diff_components VALUES (1257), (2005), (2221), (2222), (1612903), (1740031), (1230001157), (1230001159), (1234444746), (1234444747)
INSERT INTO @naat_components VALUES (268), (1558004)
INSERT INTO @rna_components VALUES (1497), (1662), (2268), (2269), (1510740), (1561915), (1230001158), (1230001163), (1230002269), (1234101169), (1234444899)
INSERT INTO @cd4_abs_components VALUES (1558135), (1230000596)
INSERT INTO @cd4_per_components VALUES (1558134), (1230000594)


/*================================================================================================================
										LAB TEST RESULTS
================================================================================================================*/
IF OBJECT_ID(N'tempdb..#LAB_RESULTS', N'U') IS NOT NULL DROP TABLE #LAB_RESULTS;

-- Labs
SELECT PAT_ID, labs.ORDER_PROC_ID,
	   ORDER_INST, SPECIMN_TAKEN_TIME, RESULT_TIME, 
	   COMPONENT_ID, ORD_VALUE, COMPONENT_COMMENT, ORD_VALUE_REPLACED,
	   TEST_TYPE,
		CASE
			WHEN TEST_TYPE = 'RNA'
				AND ISNUMERIC(ORD_VALUE_REPLACED) = 1 THEN CAST(ORD_VALUE_REPLACED as integer)
			ELSE NULL
		END as RNA_VALUE,
	   CASE 
			WHEN ORD_VALUE LIKE 'N%' THEN 'Negative'
			-- <30 Detected (unsure why mix of numeric and character exists)
			WHEN ORD_VALUE LIKE '%<%Detected%' THEN 'Positive'
			WHEN ORD_VALUE LIKE '%<%' THEN 'Negative'
			WHEN ORD_VALUE LIKE '%Target Not%' THEN 'Negative'
			WHEN ORD_VALUE LIKE 'R%' THEN 'Positive'
			WHEN ORD_VALUE LIKE 'P%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%REPEATEDLY%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%repeatedly%' THEN 'Positive'
			WHEN TEST_TYPE = 'RNA'
			-- ID 1662 is HIV-1 qualitative (RNA test)
				AND (ISNUMERIC(ORD_VALUE_REPLACED) = 1 OR ORD_VALUE = 'DETECTED') THEN 'Positive'
			ELSE NULL
		END as TEST_RESULT,
		HAS_COMMENT
INTO #LAB_RESULTS
FROM (
	SELECT PAT_ID, ORDER_PROC_ID,
	ORDER_INST, SPECIMN_TAKEN_TIME, RESULT_TIME, COMPONENT_ID, ORD_VALUE, COMPONENT_COMMENT,
		CASE
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components) THEN 'AB'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @diff_components) THEN 'Differentiation'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @naat_components) THEN 'Confirmatory'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components) THEN 'RNA'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_abs_components) THEN 'CD4 Absolute'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_per_components) THEN 'CD4 Percentage'
			ELSE NULL
		END as TEST_TYPE,
		REPLACE(REPLACE(REPLACE(ORD_VALUE, '>', ''), '=', ''), ',', '') as ORD_VALUE_REPLACED
	FROM HIV_LABS
	WHERE 1=1
		AND ORDER_STATUS_NM = 'Completed'
		--AND ORD_VALUE IS NOT NULL
		AND (
			(ORD_VALUE NOT LIKE '%INVALID%'	-- Invalid
				AND ORD_VALUE NOT LIKE '%INDETER%'	-- Indeterminant
				AND ORD_VALUE NOT LIKE '%TNP%'		-- Test not performed
				AND ORD_VALUE NOT LIKE '%EQ%'		-- Equivocal
				) OR ORD_VALUE IS NULL
			)
		AND (
			COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @diff_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @naat_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_abs_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @cd4_per_components)
			)
) as labs
LEFT JOIN (
	-- Lab comments (indicator)
	SELECT DISTINCT ORDER_PROC_ID, 1 AS HAS_COMMENT
	FROM HIV_LABS_COMMENTS 
) as comments ON comments.ORDER_PROC_ID = labs.ORDER_PROC_ID


/*================================================================================================================
							POSITIVE TEST COMMENTS FOR AB DIFFERENTIATION TESTS

When test result comments are too lage to be stored in the LAB table they are stored in 
	the LAB_COMMENTS table (one row per line of comment)

- Only for components (2221, 2222)

	!! Comments for other lab tests are not as easily classified !!
================================================================================================================*/
IF OBJECT_ID(N'tempdb..#POS_DIFF_COMMENTS', N'U') IS NOT NULL DROP TABLE #POS_DIFF_COMMENTS;

SELECT PAT_ID, lab_comments.ORDER_PROC_ID,
		-- Concatenate comments over rows (within order ID)
		string_agg(RESULTS_CMT, ' ') WITHIN GROUP (ORDER BY LINE_COMMENT ASC) as COMMENT
INTO #POS_DIFF_COMMENTS
FROM HIV_LABS_COMMENTS as lab_comments
INNER JOIN (
	SELECT ORDER_PROC_ID
	FROM #LAB_RESULTS
	-- Components (2221, 2222) are easy to parse, the rest provide little-to-no gain for the trouble
	--WHERE TEST_RESULT IS NULL
	WHERE COMPONENT_ID IN (2221, 2222)
) as null_labs on null_labs.ORDER_PROC_ID = lab_comments.ORDER_PROC_ID
WHERE 1=1
	AND (UPPER(RESULTS_CMT) LIKE '%HIV-1 POSITIVE%'
		OR UPPER(RESULTS_CMT) LIKE '%HIV-2 POSITIVE%')
GROUP BY PAT_ID, lab_comments.ORDER_PROC_ID;



/*================================================================================================================
											HIV REGISTRY

A collection of CTEs to construct the final registry table (one row per patient).

	!! Insurance is not included as no index-date was provided from which to determine coverage !!

================================================================================================================*/
WITH antibody_tests AS (
	SELECT DISTINCT PAT_ID, 1 AS AB_TESTED
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'AB'
),
reactive_antibody_tests AS (
	SELECT DISTINCT PAT_ID, 1 AS AB_REACTIVE
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'AB' AND TEST_RESULT = 'Positive'
),
differentiation_tests AS (
	SELECT DISTINCT PAT_ID, 1 AS AB_DIFF_TESTED
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'Differentiation'
),
reactive_differentiation_tests AS (
	select DISTINCT PAT_ID, 1 AS AB_DIFF_REACTIVE
	FROM #POS_DIFF_COMMENTS
	UNION (
		SELECT DISTINCT PAT_ID, 1 AS AB_DIFF_REACTIVE
		FROM #LAB_RESULTS
		WHERE TEST_TYPE = 'Differentiation' AND TEST_RESULT = 'Positive'
	)
),
reactivity_confirmatory_tests AS (
	SELECT DISTINCT PAT_ID, 1 AS AB_CONF_REACTIVE
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'Confirmatory' AND TEST_RESULT = 'Positive'
),
viral_load_date AS (
	SELECT PAT_ID, CAST(MAX(ORDER_INST) AS DATE) AS RNA_RECENT_DATE, 1 AS RNA_TESTED
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'RNA'
	GROUP BY PAT_ID
),
detected_viral_load AS (
	SELECT DISTINCT PAT_ID, 1 AS RNA_DETECTED
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'RNA' AND TEST_RESULT = 'Positive'
),
-- Should we add the nadir and/or most recent CD4 values?
cd4_tests AS (
	SELECT DISTINCT PAT_ID,  CAST(MAX(ORDER_INST) AS DATE) AS CD4_RECENT_DATE, 1 AS CD4_TESTED
	FROM #LAB_RESULTS
	WHERE TEST_TYPE = 'CD4 Absolute' OR TEST_TYPE = 'CD4 Percentage'
	GROUP BY PAT_ID
),
arv_orders AS (
	SELECT DISTINCT PAT_ID, 1 AS ARV_ORDERED
	FROM HIV_MEDICATIONS
	WHERE 1=1
		AND (ORDER_STATUS_NM != 'Canceled' OR ORDER_STATUS_NM IS NULL)
		AND UPPER(PHARM_SBCLS_LIST) LIKE '%RETROVIRAL%'
		-- some HBV treatments are anti-retrovirals
		AND (PHARM_CLASS_LIST != 'HEPATITIS B TREATMENT AGENTS' OR PHARM_CLASS_LIST IS NULL)
		-- not Truvada or Descovy (PrEP)
		AND ATC_CODE NOT IN ('J05AR03', 'J05AR17')
),
last_completed_encounter AS (
	SELECT PAT_ID, CAST(MAX(CONTACT_DATE) AS DATE) AS LAST_SEEN_DATE
	FROM HIV_ENCOUNTERS
	WHERE 1=1
		AND (APPT_STATUS_NM IN ('Completed') OR HOSP_DISCH_TIME IS NOT NULL)
		AND (UPPER(ENC_TYPE_NM) NOT LIKE '%ERRONEOUS%' OR ENC_TYPE_NM IS NULL)
	GROUP BY PAT_ID
),
last_engaged_in_care AS (
	SELECT PAT_ID, CAST(MAX(CONTACT_DATE) AS DATE) AS LAST_ENGAGED_DATE
	FROM HIV_ENCOUNTERS
	WHERE 1=1
		AND APPT_STATUS_NM IN ('Completed')
		AND (UPPER(ENC_TYPE_NM) NOT LIKE '%ERRONEOUS%' OR ENC_TYPE_NM IS NULL)
		AND (DEPARTMENT_NAME LIKE '%HEALING WINGS%' 
			OR DEPARTMENT_NAME LIKE '%TRUE WORTH%'
			-- seen while in jail
			OR DEPARTMENT_NAME LIKE '%CORRECTIONAL FACILITY%'
			)
	GROUP BY PAT_ID
)
SELECT pats.PAT_ID, PAT_MRN_ID,
		DATEDIFF(year, BIRTH_DATE, CAST(GETDATE() AS DATE)) AS AGE,
		CASE WHEN PAT_SEX IS NULL THEN 'Unknown' ELSE PAT_SEX END AS SEX, 
		PATIENT_RACE AS RACE_PRIMARY,
		ETHNIC_GROUP_NM AS HISPANIC_YN,
		CASE
			WHEN ETHNIC_GROUP_NM = 'Hispanic, Latino or Spanish ethnicity' THEN 'Hispanic'
			WHEN PATIENT_RACE LIKE '%BLACK%' THEN 'NH Black'
			WHEN (PATIENT_RACE LIKE '%ASIAN%' OR PATIENT_RACE LIKE '%INDIAN%' OR PATIENT_RACE LIKE '%HAWAIIAN%' OR PATIENT_RACE LIKE '%OTHER%')
				AND PATIENT_RACE NOT LIKE '%CAUCASIAN%' THEN 'NH Other'
			WHEN PATIENT_RACE LIKE '%CAUCASIAN%' THEN 'NH White'
			ELSE 'Unknown'
		END AS RACETH,
		ISNULL(AB_TESTED, 0) AS AB_TESTED,
		ISNULL(AB_REACTIVE, 0) AS AB_REACTIVE,
		ISNULL(AB_DIFF_TESTED, 0) AS AB_DIFF_TESTED, 
		ISNULL(AB_DIFF_REACTIVE, 0) AS AB_DIFF_REACTIVE,
		ISNULL(AB_CONF_REACTIVE, 0) AS AB_CONF_REACTIVE,
		ISNULL(RNA_TESTED, 0) AS RNA_TESTED,
		RNA_RECENT_DATE,
		DATEDIFF(day, RNA_RECENT_DATE, CAST(GETDATE() AS DATE)) AS DAYS_SINCE_RNA,
		ISNULL(RNA_DETECTED, 0) AS RNA_DETECTED,
		ISNULL(CD4_TESTED, 0) AS CD4_TESTED,
		CD4_RECENT_DATE,
		DATEDIFF(day, CD4_RECENT_DATE, CAST(GETDATE() AS DATE)) AS DAYS_SINCE_CD4,
		ISNULL(ARV_ORDERED, 0) AS ARV_ORDERED,
		LAST_SEEN_DATE,
		LAST_ENGAGED_DATE,
		CASE
			WHEN 1=1
				AND (AB_DIFF_REACTIVE = 1 OR AB_CONF_REACTIVE = 1 OR RNA_DETECTED = 1 OR ARV_ORDERED = 1)
				AND (RNA_TESTED =1 OR CD4_TESTED = 1)
				AND LAST_ENGAGED_DATE IS NOT NULL THEN 'HIVCOR' ELSE 'Excluded'
			END AS HIVCOR
FROM HIV_PATIENTS as pats
LEFT JOIN antibody_tests ON antibody_tests.PAT_ID = pats.PAT_ID
LEFT JOIN reactive_antibody_tests ON reactive_antibody_tests.PAT_ID = pats.PAT_ID
LEFT JOIN differentiation_tests ON differentiation_tests.PAT_ID = pats.PAT_ID
LEFT JOIN reactive_differentiation_tests ON reactive_differentiation_tests.PAT_ID = pats.PAT_ID
LEFT JOIN reactivity_confirmatory_tests ON reactivity_confirmatory_tests.PAT_ID = pats.PAT_ID
LEFT JOIN viral_load_date ON viral_load_date.PAT_ID = pats.PAT_ID
LEFT JOIN detected_viral_load ON detected_viral_load.PAT_ID = pats.PAT_ID
LEFT JOIN cd4_tests ON cd4_tests.PAT_ID  = pats.PAT_ID
LEFT JOIN arv_orders ON arv_orders.PAT_ID = pats.PAT_ID
LEFT JOIN last_completed_encounter ON last_completed_encounter.PAT_ID = pats.PAT_ID
LEFT JOIN last_engaged_in_care ON last_engaged_in_care.PAT_ID = pats.PAT_ID
