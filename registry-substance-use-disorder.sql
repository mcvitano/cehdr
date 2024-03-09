/* =======================================================================================================================================
Project:		Substance Use Registry (CEHDR)
Author:			Matt Cvitanovich
Create date: 	2024-01-17
Update date:
Description:	Creates a single patient-level file of (dates of) substance use disorders
					for CEHDR research projects.
Steps:
	(1) Create temp table containing medication orders for naloxone from Emergency admisisons
	(2) Use CTEs to pull together patients' most recent diagnosis date for each substance use disorder,
		medication orders for buprenorphine, demographics, most recently completed appointment or 
		hospital admission ... merging in naloxone orders from the temp table.

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

-- Temp table for Naloxone in the ED
IF OBJECT_ID(N'tempdb..#NALOXONE_ED', N'U') IS NOT NULL
DROP TABLE #NALOXONE_ED;

-- Naloxone (V03AB15)
--		Ordered while provider OR patient in Emergency
--		AND
--		Emergency admission < any Inpatient or Outpatient
SELECT S.PAT_ID, MAX(S.ORDERING_DATE) AS NALOXONE_ORDER_DATE
INTO #NALOXONE_ED
FROM (
	-- Subquery for CSNS of Emergency admissions
	SELECT DISTINCT MEDS.PAT_ID, MEDS.PAT_ENC_CSN_ID, ATC_CODE, ORDERING_DATE
	FROM SUBSTANCE_USE_MEDICATIONS AS MEDS	
	INNER JOIN (
		SELECT PAT_ID, PAT_ENC_CSN_ID
		FROM SUBSTANCE_USE_ENCOUNTERS
		WHERE 1=1
			AND EMER_ADM_DATE IS NOT NULL 
			AND (INP_ADM_DATE IS NULL OR INP_ADM_DATE > EMER_ADM_DATE)
			AND (OP_ADM_DATE IS NULL OR OP_ADM_DATE > EMER_ADM_DATE)
			) AS ENCS ON MEDS.PAT_ID = ENCS.PAT_ID AND MEDS.PAT_ENC_CSN_ID = ENCS.PAT_ENC_CSN_ID
	WHERE 1 = 1
		AND ATC_CODE = 'V03AB15'
		AND (ORDERING_PROV_LOGIN_LOC = 'JPS EMERGENCY' OR PAT_LOC_AT_ORDER = 'JPS EMERGENCY')
	) AS S
GROUP BY S.PAT_ID;

--SELECT * FROM #NALOXONE_ED ORDER BY PAT_ID OFFSET 10 ROWS FETCH NEXT 10 ROWS ONLY;



-- CTE containing patients' most recent diagnosis for each substance
WITH CTE_RECENT_SUD_DATES (PAT_ID, 
	ALCOHOL_DX_DATE, OPIOID_DX_DATE, 
	CANNABIS_DX_DATE, SEDATIVE_DX_DATE, 
	COCAINE_DX_DATE, OTHER_STIMULANT_DX_DATE, 
	METHAMPHETAMINE_DX_DATE, HALLUCINOGEN_DX_DATE, 
	NICOTINE_DX_DATE, INHALANT_DX_DATE,
	OTHER_PSYCHOACTIVE_DX_DATE)
AS (
	SELECT PAT_ID,
		-- Alcohol
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F10%' THEN CONTACT_DATE
			ELSE NULL
		END AS ALCOHOL_DX_DATE,
		-- Opioid
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F11%'
				OR DX_NAME LIKE '%Opiate%'
				OR DX_NAME LIKE '%Opioid%'
				OR DX_NAME LIKE '%Methadone%'
				OR DX_NAME LIKE '%Heroin%'
				OR DX_NAME LIKE '%Fentanyl%' THEN CONTACT_DATE
			ELSE NULL
		END AS OPIOID_DX_DATE,
		-- Cannabis
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F12%' THEN CONTACT_DATE
			ELSE NULL
		END AS CANNABIS_DX_DATE,
		-- Sedative
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F13%' THEN CONTACT_DATE
			ELSE NULL
		END AS SEDATIVE_DX_DATE,
		-- Cocaine
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F14%' THEN CONTACT_DATE
			ELSE NULL
		END AS COCAINE_DX_DATE,
		-- Other Stimulant (if not Methamphetamine)
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F15%' 
			AND DX_NAME NOT LIKE '%Methamp%' THEN CONTACT_DATE
			ELSE NULL
		END AS OTHER_STIMULANT_DX_DATE,
		-- Methamphetamine
		CASE
			WHEN DX_NAME LIKE '%Methamp%' THEN CONTACT_DATE
			ELSE NULL
		END AS METHAMPHETAMINE_DX_DATE,
		-- Hallucinogen
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F16%' THEN CONTACT_DATE
			ELSE NULL
		END AS HALLUCINOGEN_DX_DATE,
		-- Nicotine
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F17%' THEN CONTACT_DATE
			ELSE NULL
		END AS NICOTINE_DX_DATE,
		-- Inhalant
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F18%' THEN CONTACT_DATE
			ELSE NULL
		END AS INHALANT_DX_DATE,
		-- Other Psychoactive (if not opioid or methamphetamine)
		CASE
			WHEN CURRENT_ICD10_LIST LIKE '%F19%' 
				AND DX_NAME NOT LIKE '%Opiate%'
				AND DX_NAME NOT LIKE '%Opioid%'
				AND DX_NAME NOT LIKE '%Methadone%'
				AND DX_NAME NOT LIKE '%Heroin%'
				AND DX_NAME NOT LIKE '%Fentanyl%'
				AND DX_NAME NOT LIKE '%Methamp%' THEN CONTACT_DATE
			ELSE NULL
		END AS OTHER_PSYCHOACTIVE_DX_DATE
	FROM SUBSTANCE_USE_DIAGNOSIS_LIST
	),
-- CTE containing patients' most recent order for buprenorphine
CTE_BUPRENORPHINE (PAT_ID, BUP_ORDER_DATE)
AS  (
	SELECT PAT_ID, MAX(ORDERING_DATE) AS BUP_ORDER_DATE
	FROM SUBSTANCE_USE_MEDICATIONS
	WHERE ATC_CODE IN ('N07BC01', 'N07BC51')
	GROUP BY PAT_ID
	),
-- CTE containing patients' demographics + most recently completed appointment or admission
CTE_SUD_DEMOGRAPHICS (PAT_ID, AGE_YRS, SEX, RACETH, RECENT_CONTACT_DATE, ENC_TYPE_NM, DEPARTMENT_NAME)
AS (
	-- Demographics
	SELECT PATS.PAT_ID, 
		DATEDIFF(YEAR, BIRTH_DATE, GETDATE()) AS AGE_YRS,
		CASE 
			WHEN PAT_SEX IS NULL THEN 'Unknown'
			ELSE PAT_SEX
		END AS SEX,
		CASE
			WHEN ETHNIC_GROUP_NM = 'Hispanic, Latino or Spanish ethnicity' THEN 'Hispanic'
			WHEN PATIENT_RACE LIKE '%BLACK%' THEN 'NH Black'
			WHEN (PATIENT_RACE LIKE '%ASIAN%' OR PATIENT_RACE LIKE '%INDIAN%' OR PATIENT_RACE LIKE '%HAWAIIAN%' OR PATIENT_RACE LIKE '%OTHER%')
				AND PATIENT_RACE NOT LIKE '%CAUCASIAN%' THEN 'NH Other'
			WHEN PATIENT_RACE LIKE '%CAUCASIAN%' THEN 'NH White'
			ELSE 'Unknown'
		END AS RACETH,
		CAST(CONTACT_DATE AS DATE) AS RECENT_CONTACT_DATE, 
		ENC_TYPE_NM,
		DEPARTMENT_NAME
	FROM SUBSTANCE_USE_PATIENTS AS PATS
	-- Recent appointment (completed) or admission
	LEFT JOIN (
		SELECT PAT_ID, 
		CONTACT_DATE, 
		ENC_TYPE_NM,
		DEPARTMENT_NAME,
		ROW_NUMBER() OVER(PARTITION BY PAT_ID ORDER BY CONTACT_DATE DESC) AS RN
		FROM SUBSTANCE_USE_ENCOUNTERS
		WHERE 1=1
			AND APPT_STATUS_NM = 'Completed' OR HOSP_ADMSN_TIME IS NOT NULL
			) AS ENCS ON PATS.PAT_ID = ENCS.PAT_ID
	WHERE RN = 1
)
-- Outer query referencing the CTEs
SELECT CT3.PAT_ID,
	-- Must use MAX() since using a GROUP BY()
	MAX(AGE_YRS) AS AGE_YRS, 
	MAX(SEX) AS SEX, 
	MAX(RACETH) AS RACETH,
	MAX(RECENT_CONTACT_DATE) AS RECENT_CONTACT_DATE,
	MAX(ENC_TYPE_NM) AS ENC_TYPE_NM,
	MAX(DEPARTMENT_NAME) AS DEPARTMENT_NAME,
	-- Use MAX() to keep only most recent diagnosis date for each substance
	CAST(MAX(ALCOHOL_DX_DATE) AS DATE) AS ALCOHOL_DX_DATE, 
	CAST(MAX(OPIOID_DX_DATE) AS DATE) AS OPIOID_DX_DATE, 
	CAST(MAX(CANNABIS_DX_DATE) AS DATE) AS CANNABIS_DX_DATE, 
	CAST(MAX(SEDATIVE_DX_DATE) AS DATE) AS SEDATIVE_DX_DATE, 
	CAST(MAX(COCAINE_DX_DATE) AS DATE) AS COCAINE_DX_DATE, 
	CAST(MAX(OTHER_STIMULANT_DX_DATE) AS DATE) AS OTHER_STIMULANT_DX_DATE, 
	CAST(MAX(METHAMPHETAMINE_DX_DATE) AS DATE) AS METHAMPHETAMINE_DX_DATE, 
	CAST(MAX(HALLUCINOGEN_DX_DATE) AS DATE) AS HALLUCINOGEN_DX_DATE, 
	CAST(MAX(NICOTINE_DX_DATE) AS DATE) AS NICOTINE_DX_DATE, 
	CAST(MAX(INHALANT_DX_DATE) AS DATE) AS INHALANT_DX_DATE,
	CAST(MAX(OTHER_PSYCHOACTIVE_DX_DATE) AS DATE) AS OTHER_PSYCHOACTIVE_DX_DATE,
	CAST(MAX(BUP_ORDER_DATE) AS DATE) AS BUP_ORDER_DATE,
	CAST(MAX(NALOXONE_ORDER_DATE) AS DATE) AS NALOXONE_ORDER_DATE
FROM CTE_SUD_DEMOGRAPHICS AS CT3
LEFT JOIN CTE_RECENT_SUD_DATES AS CT1 ON CT1.PAT_ID = CT3.PAT_ID
LEFT JOIN CTE_BUPRENORPHINE AS CT2 ON CT2.PAT_ID = CT3.PAT_ID
LEFT JOIN #NALOXONE_ED AS TMP ON TMP.PAT_ID = CT3.PAT_ID
GROUP BY CT3.PAT_ID;
