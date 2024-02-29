
/* =======================================================================================================================================
Project:		HCV Registry (CEHDR)
Author:			Matt Cvitanovich
Create date:	2024-02-27
Update date:

Description:	
	Identifies patients in the CEHDR HCV_PATIENTS database table as 'eligible' for the HCV regsitry.
	The crieria for inclusion is:
		(1) Any of the following:
				- "reactive" HCV antibody test
				- "detectable" HCV RNA (viral load) test
				- valid HCV genotype test result
				- medication order for HCV treatment
				- "active" HCV medication

	Note:
		- This script does NOT provide dates of entry/eligibility or lab test values (which are date-dependent)
		- Technically, any result from an HCV resistance test indicates HCV(+) status as the test requies
			a minimum viral load in order to run (all other samples will be rejected) ... Unfortunately, until circa 2022
			these test results are not included in the LABS table

Steps:
	(1) Contruct temp table of lab test results using a curated list of component IDs
	(2) Use CTEs to merge requested data fields into the PATIENT table


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
	FROM HCV_LABS
	WHERE 1=1
		AND (COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @genotype_components)
			)
	GROUP BY COMPONENT_ID, COMPONENT_NM;

---------------------------------------------------------------------------------------------------
											IN SERVICE
---------------------------------------------------------------------------------------------------
													~ START		~ END			TEST_TYPE
1230000019	HEPATITIS C ANTIBODY, IGG				2020-08		(in use)		AB Screen

1230001113	HCV QNT BY NAAT (IU/ML)					2021-11		(in use)		RNA

1230001115	HCV GENOTYPE BY SEQUENCING				2021-11		(in use)		Genotype

---------------------------------------------------------------------------------------------------
										OUT OF SERVICE
---------------------------------------------------------------------------------------------------
													~ START		~ END			TEST_TYPE
1526626		HEPATITIS C ANTIBODY					2011-05		2021-11			AB Screen

1811181		HEPATITIS C RNA-PCR						2011-05		2012-12			RNA
30400316	HCV IU/ML								2011-05		2016-06			RNA
784			HEPATITIS C VIRUS RNA QUAL				2011-12		2020-09			RNA
2236		IU/ML, HCV QNT							2016-06		2021-11			RNA
4338		HCV RNA, PCR QUANT						2020-08		2020-08			RNA

1811182		HEPATITIS C GENOTYPE					2011-05		2021-11			Genotype
2618		HCV HIGH-RES GENOTYPE					2016-03		2021-01			Genotype
3061		NS5A GENOTYPE							2017-10		2021-11			Genotype
*/


-- Declare lab test components as tables
DECLARE @ab_components table (COMPONENT_ID int)
DECLARE @rna_components table (COMPONENT_ID int)
DECLARE @genotype_components table (COMPONENT_ID int)

-- Set values
INSERT INTO @ab_components VALUES (1526626), (1230000019)
INSERT INTO @rna_components VALUES (784), (1811181), (4338), (30400316), (1230001110), (1230001112), (1230001113), (2236), (2337) 
INSERT INTO @genotype_components VALUES (2618), (3061), (1230001115), (1811182)



/*================================================================================================================
										LAB TEST RESULTS
================================================================================================================*/
IF OBJECT_ID(N'tempdb..#LAB_RESULTS', N'U') IS NOT NULL DROP TABLE #LAB_RESULTS;

-- Labs
SELECT PAT_ID, ORDER_PROC_ID,
	   ORDER_INST, SPECIMN_TAKEN_TIME, RESULT_TIME, 
	   COMPONENT_ID, ORD_VALUE, COMPONENT_COMMENT, 
	   --ORD_VALUE_REPLACED,
	   TEST_TYPE,
		CASE
			WHEN TEST_TYPE = 'RNA'
				AND ISNUMERIC(ORD_VALUE_REPLACED) = 1 THEN CAST(ORD_VALUE_REPLACED as FLOAT)
			ELSE NULL
		END as RNA_VALUE,
		/* case-when is order-specific:
			(1) First			'%<[0-9]%DETECTED%'
			(2) Genotype		'%[1-6]%'
			(3) Non-reactive	COMPONENT_COMMENT pieces
			(4) Non-reactive	ORDER_VALUE pieces
			(5) Reactive		(any order) */
	   CASE 
			-- Mixed dtypes; <15 DETECTED
			WHEN ORD_VALUE LIKE '%<[0-9]%DETECTED%' THEN 'Positive'

			-- genotype
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @genotype_components) AND ORD_VALUE LIKE '%[1-6]%' THEN 'Positive'

			-- non-reactive/not detected
			WHEN COMPONENT_COMMENT LIKE '%NON%REACTIVE%' THEN 'Negative'
			WHEN COMPONENT_COMMENT LIKE '%NOT%DETECTED%' THEN 'Negative'
			WHEN COMPONENT_COMMENT LIKE '%LESS THAN%' THEN 'Negative'
			WHEN COMPONENT_COMMENT LIKE '%<%' THEN 'Negative'
			WHEN ORD_VALUE LIKE '%NON%' THEN 'Negative'
			WHEN ORD_VALUE LIKE '%NOT%DETECTED' THEN 'Negative'
			WHEN ORD_VALUE LIKE '%<%' THEN 'Negative'

			-- reactive/detected
			WHEN ORD_VALUE LIKE '%REACTIVE%' THEN 'Positive'
			WHEN ORD_VALUE LIKE '%DETECTED%' THEN 'Positive'
			WHEN ORD_VALUE LIKE '%[0-9]%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%REPEATEDLY%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%CONFIRMATION%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%DETECTED%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%GREATER THAN%' THEN 'Positive'
			WHEN COMPONENT_COMMENT LIKE '%>%' THEN 'Positive'
			ELSE NULL
		END as TEST_RESULT
INTO #LAB_RESULTS
FROM (
	-- Inner-subquery (filter out invalid test results & categorize test types)
	SELECT PAT_ID, ORDER_PROC_ID,
		ORDER_INST, SPECIMN_TAKEN_TIME, RESULT_TIME, COMPONENT_ID, 
		UPPER(ORD_VALUE) as ORD_VALUE, 
		UPPER(COMPONENT_COMMENT) as COMPONENT_COMMENT,
		CASE
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components) THEN 'AB'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components) THEN 'RNA'
			WHEN COMPONENT_ID IN (SELECT COMPONENT_ID FROM @genotype_components) THEN 'Genotype'
			ELSE NULL
		END as TEST_TYPE,
		REPLACE(REPLACE(REPLACE(ORD_VALUE, '>', ''), '=', ''), ',', '') as ORD_VALUE_REPLACED
	FROM HCV_LABS
	WHERE 1=1
		AND ORDER_STATUS_NM = 'Completed'
		AND ORD_VALUE IS NOT NULL
		AND (
			(ORD_VALUE NOT LIKE '%INVALID%'	-- Invalid
				AND ORD_VALUE NOT LIKE '%INDETER%'	-- Indeterminant
				AND ORD_VALUE NOT LIKE '%TNP%'		-- Test not performed
				AND ORD_VALUE NOT LIKE '%EQ%'		-- Equivocal
				)
			)
		AND (
			COMPONENT_ID IN (SELECT COMPONENT_ID FROM @ab_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @rna_components)
			OR COMPONENT_ID IN (SELECT COMPONENT_ID FROM @genotype_components)
			)
) as labs



/*================================================================================================================
										PATIENTS FLAGGED FOR REGISTRY
================================================================================================================*/

IF OBJECT_ID(N'tempdb..#REGISTRY_FLAGGED', N'U') IS NOT NULL DROP TABLE #REGISTRY_FLAGGED;

-- Reactive AB (first)
WITH reactive_ab AS (
	SELECT PAT_ID, 
		MIN(RESULT_TIME) AS FIRST_REACTIVE_DATE
	FROM #LAB_RESULTS
	WHERE 1=1
		AND TEST_TYPE = 'AB'
		AND TEST_RESULT = 'Positive'
	GROUP BY PAT_ID
	),
-- Detectable RNA (first)
detected_rna AS (
	SELECT PAT_ID,
		MIN(RESULT_TIME) AS FIRST_DETECTED_DATE
	FROM #LAB_RESULTS
	WHERE 1=1
		AND TEST_TYPE = 'RNA'
		AND TEST_RESULT = 'Positive'
	GROUP BY PAT_ID
	),
-- Genotype (first)
genotype AS (
	SELECT PAT_ID, 
		MIN(RESULT_TIME) AS FIRST_GENOTYPE_DATE
	FROM #LAB_RESULTS
	WHERE 1=1
		AND TEST_TYPE = 'Genotype'
		AND TEST_RESULT = 'Positive'
	GROUP BY PAT_ID
	),
-- treatment order
treatment_order AS (
	SELECT PAT_ID,
			MIN(inner_query.MED_START_DATE) AS FIRST_TRT_ORDER_DATE
	FROM (
		-- get minimum (start date, ordering date)
		SELECT PAT_ID, ATC_TITLE,
			CASE WHEN START_DATE < ORDERING_DATE THEN START_DATE
				 ELSE ORDERING_DATE
			END AS MED_START_DATE
		FROM HCV_MEDICATIONS
			) AS inner_query
	WHERE 1=1
		-- List is based on data prior to Jan .2024
		-- List should be complete (only generic names are used in ATC titles)
		AND (
			ATC_TITLE LIKE '%BOCEPREVIR%' OR
			ATC_TITLE LIKE '%DACLATASVIR%' OR
			ATC_TITLE LIKE '%DASABUVIR%' OR
			ATC_TITLE LIKE '%ELBASVIR%' OR
			ATC_TITLE LIKE '%GLECAPREVIR%' OR
			ATC_TITLE LIKE '%GRAZOPREVIR%' OR
			ATC_TITLE LIKE '%INTERFERON ALFA%' OR
			ATC_TITLE LIKE '%LEDIPASVIR%' OR
			ATC_TITLE LIKE '%OMBITASVIR%' OR
			ATC_TITLE LIKE '%PARITAPREVIR%' OR
			ATC_TITLE LIKE '%PEGINTERFERON%' OR
			ATC_TITLE LIKE '%PIBRENTASVIR%' OR
			ATC_TITLE LIKE '%SIMEPREVIR%' OR
			ATC_TITLE LIKE '%SOFOSBUVIR%' OR
			ATC_TITLE LIKE '%TELAPREVIR%' OR
			ATC_TITLE LIKE '%VELPATASVIR%' OR
			ATC_TITLE LIKE '%VOXILAPREVIR%'
			)
	GROUP BY PAT_ID
	),
-- treatment (active; not all HCV medication is ordered in Epic)
treatment_active AS (
	SELECT PAT_ID,
			MIN(inner_query.MED_START_DATE) AS FIRST_TRT_ACTIVE_DATE
	FROM (
		-- get minimum (start date, ordering date)
		SELECT PAT_ID, MEDICATION_NAME,
			CASE WHEN START_DATE < ORDERING_DATE THEN START_DATE
				 ELSE ORDERING_DATE
			END AS MED_START_DATE
		FROM HCV_MEDICATIONS_ACTIVE
			) AS inner_query
	WHERE 1=1
		-- List is based on manual review of data prior to Jan .2024
		-- List is incomplete (provider may enter either generic or brand name)
		-- Likely doesn't add much value in recent years 
		--	now that Mavyret has been added to the formulary and endorsed by CMS
		AND (
			MEDICATION_NAME LIKE '%BOCEPREVIR%' OR
			MEDICATION_NAME LIKE '%DACLATASVIR%' OR
			MEDICATION_NAME LIKE '%DASABUVIR%' OR
			MEDICATION_NAME LIKE '%DAKLINZA%' OR
			MEDICATION_NAME LIKE '%ELBASVIR%' OR
			MEDICATION_NAME LIKE '%GLECAPREVIR%' OR
			MEDICATION_NAME LIKE '%GRAZOPREVIR%' OR
			MEDICATION_NAME LIKE '%INTERFERON ALFA%' OR
			MEDICATION_NAME LIKE '%INCIVEK%' OR
			MEDICATION_NAME LIKE '%INFERGEN%' OR
			MEDICATION_NAME LIKE '%LEDIPASVIR%' OR
			MEDICATION_NAME LIKE '%MAVYRET%' OR
			MEDICATION_NAME LIKE '%OLYSIO%' OR
			MEDICATION_NAME LIKE '%OMBITASVIR%' OR
			MEDICATION_NAME LIKE '%PARITAPREVIR%' OR
			MEDICATION_NAME LIKE '%PEGINTERFERON%' OR
			MEDICATION_NAME LIKE '%PEGASYS%' OR
			MEDICATION_NAME LIKE '%PIBRENTASVIR%' OR
			MEDICATION_NAME LIKE '%SIMEPREVIR%' OR
			MEDICATION_NAME LIKE '%SOFOSBUVIR%' OR
			MEDICATION_NAME LIKE '%TELAPREVIR%' OR
			MEDICATION_NAME LIKE '%VELPATASVIR%' OR
			MEDICATION_NAME LIKE '%VOXILAPREVIR%' OR
			MEDICATION_NAME LIKE '%ZEPATIER%'
			)
	GROUP BY PAT_ID
	)
SELECT pats.PAT_ID, 
		FIRST_REACTIVE_DATE, FIRST_DETECTED_DATE, FIRST_GENOTYPE_DATE,
		FIRST_TRT_ORDER_DATE, FIRST_TRT_ACTIVE_DATE, 
		CASE
			WHEN FIRST_REACTIVE_DATE IS NOT NULL THEN 1
			WHEN FIRST_DETECTED_DATE IS NOT NULL THEN 1
			WHEN FIRST_GENOTYPE_DATE IS NOT NULL THEN 1
			WHEN FIRST_TRT_ORDER_DATE IS NOT NULL THEN 1
			WHEN FIRST_TRT_ACTIVE_DATE IS NOT NULL THEN 1
			ELSE 0
		END AS HCV_REGISTRY_ELIGIBLE
INTO #REGISTRY_FLAGGED
FROM HCV_PATIENTS AS pats
LEFT JOIN reactive_ab
	ON reactive_ab.PAT_ID = pats.PAT_ID
LEFT JOIN detected_rna
	ON detected_rna.PAT_ID = pats.PAT_ID
LEFT JOIN genotype
	ON genotype.PAT_ID = pats.PAT_ID
LEFT JOIN treatment_order
	ON treatment_order.PAT_ID = pats.PAT_ID
LEFT JOIN treatment_active
	ON treatment_active.PAT_ID = pats.PAT_ID


-- 16,670 flagged out of 17,501 patients in existing HCV registry
SELECT COUNT(DISTINCT PAT_ID) AS IN_REGISTRY,
	   SUM(HCV_REGISTRY_ELIGIBLE) AS ELIGIBLE
FROM #REGISTRY_FLAGGED;



/* Validation

-- Review labs

SELECT DISTINCT COMPONENT_ID, COMPONENT_NM, TEST_TYPE, TEST_RESULT, ORD_VALUE, COMPONENT_COMMENT
FROM #LAB_RESULTS;


-- Review unflagged patients' labs (include all labs in case I missed some relevant HCV tests)

SELECT flags.PAT_ID, PAT_ENC_CSN_ID, 
	PROC_CODE, ORDER_DESCRIPTION, COMPONENT_ID, COMPONENT_NM, 
	ORD_VALUE, COMPONENT_COMMENT
FROM HCV_LABS AS labs 
INNER JOIN #REGISTRY_FLAGGED AS flags 
	ON labs.PAT_ID = flags.PAT_ID
WHERE 1=1
	AND HCV_REGISTRY_ELIGIBLE = 0
	AND (
		UPPER(COMPONENT_NM) LIKE '%HCV%' OR 
		UPPER(COMPONENT_NM) LIKE '%HEPATITIS C%'
		);


-- Will have to review a few of these patients as well (for clues as to missing labs, etc. that should be considered)

SELECT * FROM #REGISTRY_FLAGGED WHERE FIRST_DETECTED_DATE IS NULL AND FIRST_REACTIVE_DATE IS NULL AND HCV_REGISTRY_ELIGIBLE=1;
*/