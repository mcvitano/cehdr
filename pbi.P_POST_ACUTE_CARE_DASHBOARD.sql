SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE pbi.P_POST_ACUTE_CARE_DASHBOARD
AS
BEGIN

-- SET NOCOUNT ON


/******************************************************************************
	PROJECT NAME:	Post-acute Care Dashboard
	CREATED BY:		Joshua Manning
	CREATE DATE:	03/18/2021
	UPDATE DATE:	02/15/2023

	DESCRIPTION:	The Post-acute Care Dashboard stored procedure supports
					visualization of key information about JPS Connection patients’
					stays at post-acute care facilities for the Post-acute Care Dashboard. 
					It generates two data mart tables, one containing skilled nursing 
					and long-term care claims data and another containing a list 
					of admissions to the hospital that occurred during the patients’ 
					stays at those facilities.


	STEPS:			1)  Prepare a list of parent facility names
					2)  Get all SNF and LTC claims from arc.V_QicLinkData
					3)  Make manual corrections to provider information
						3A) Change provider ID for deprecated Downtown Health and Rehab claims to the new Downtown Health-SNF record
						3B) Align names of duplicate provider records for Kindred Hospital - Tarrant County
					4)  Correct the dates of service on claims with a single date of service and multiple billed bed days
					5)  Correct the dates of service on claims for LTHC Solutions, which have only a single DOS apiece and are showing up as separate stays
					6)  Group claim lines into stays and determine length of stay based on the number of units billed with R&B revenue/CPT codes
						6A) Apply gaps and islands logic to identify related claims for the same patient and facility with adjacent or overlapping dates of service
					7)  Correct cases where a single stay was incorrectly split into multiple stays
						7A) Get instances where a single stay was incorrectly split into multiple stays due to the initial claim having the full date range and two or more subsequent claims having dates of service within the full range
						7B) Correct the stay end date of the first part of the stay to be the actual end date
						7C) Correct the stay begin date of the second part of the stay to be the actual begin date
						7D) Correct the SNF stay of the second part of the stay to be the SNF stay ID of the first part of the stay
						7E) Recalculate the total paid amount and length of stay for the isles that were merged in the above update statements
					8) 	Adjust length of stay in special cases
						8A) Change length of stay to units if the only R&B codes in the stay had a remark of 'Date range not valid with units submitted'
						8B) In cases where the length of stay is greater than the total dates of service in the stay due to multiple paid charges for the same dates of service, change the length of stay to the total dates of service
					9)  Remove stays at Parkview that did not have any inpatient charges with room and board (accommodation) revenue codes. Per Tina Whitfield and Tammy Boozer, these were billed incorrectly and do not represent inpatient stays.
					10) Get demographics and care team information for patients in SNF data pull
					11) Get all hospital encounters for patients in SNF data pull from 14 days prior to SNF entry to 30 days after SNF discharge
					12) Break out admits from SNF into a separate temp table in preparation for pulling inpatient readmission information
					13) Get inpatient readmissions for hospital visits that occurred during SNF/LTC stays
					14) Combine hospital visits tables
					15) Combine temp tables from prior steps to create a detail table for SNF/LTC utilization
					16)	Create or truncate landing tables and insert data
						16A) SNF/LTC claims
						16B) Hospital admits during stays

--------------------------------------------------------------------------------
MODIFICATION HISTORY
--------------------------------------------------------------------------------
MODIFY DATE		MODIFIED BY			CHANGE DESCRIPTION
--------------------------------------------------------------------------------
01/25/2022		Joshua Manning		* Changed @END to be end of previous day instead of end of
									orevious month so that the dashboard will be as up to date
									as possible.
									* Added #ISLETS to correct instances where a single stay was
									incorrectly split into multiple stays due to the initial
									claim having the full date range and two or more subsequent
									claims having dates of service within the full range.
									Removed variable @START and related filters. The start
									date criteria is no longer necessary because the dashboard
									should include all historical claims.
01/28/2022		Joshua Manning		Cleaned up code, added more in-line comments, and added
									flower box.
02/16/2022		Joshua Manning		I discovered that the granularity of the claim detail table
									in QicLink is actually not one row per claim line. There can
									be multiple rows in the claim detail table for a single claim
									line if the charge was edited or reversed. The subsequent
									rows will have a LINE_COUNTER > 0. I added an INNER JOIN
									to a subquery that returns the max LINE_COUNTER for each
									claim line to ensure that there will only be one row
									evaluated per claim line, i.e. the most recent one based
									on the line counter.
									Also renamed references to columns in arc.V_QicLinkData
									to reflect recent expansions of abbreviated names.
02/18/2022		Joshua Manning		Made the provider name in #SNF default to the provider name
									from QicLink if it does not exist in #PARENTS so that
									name values will still populate if the names change in the
									source data or new providers are introduced. Need to look at
									changing this to pull in provider ID from QicLink.
									Also made the parent facility name default to the provider
									name if a parent facility isn't specified in step 1 for
									the same reason.
02/23/2022		Joshua Manning		Changed date range criteria for ADMIT_FROM_SNF column in
									#HOSP_VISITS to take into account admissions where the
									patient did not return by midnight and the facility ended
									billing with the previous day. The column now flags an
									admit as being a direct admit from the SNF/LTC facility
									if the admission date was on the day after the last billed
									date on the claim.
03/30/2022		Joshua Manning		Added update to #SNF to correct issues with claims for
									LTHC Solutions, which have only a single DOS apiece with a
									few days' gap in between, causing them to be counted as
									separate stays even though they were actually for the same
									continuous stay. This issue has only occurred for one patient
									and stay, so it may be just an isolated incident.  I
									couldn't think of a way to make the query accommodate
									potential future cases for other patients. In the meantime,
									I have hardcoded the query to affect only this one case
									so that it doesn't improperly group claims for another
									patient down the road. Unfortunately, it will no longer work
									if the patient's current MRN gets merged. The logic may
									need to be adjusted in the future.
04/05/2022		Joshua Manning		1) Increased the granularity of the claims detail table from
									   	one row per claim number to one row per claim line. This
									   	was necessary to properly account for cases where a single
									   	claim had charges for multiple stays for the same patient
									   	on different worksheets/lines. Restricted claim lines to
									   	the line with the maximum line counter value for the line
									   	number to eliminate duplicates.
									2) Removed merged MRN matching queries because the
									   	arc.LoadQicLinkData stored procedure already does this
									   	every time it runs.
									3) Added exclusion on voided claim lines by referencing
									   	the LINE_DUPLICATE_COUNTER column in QicLinkData. If the
									   	value in that column is greater than 0, the line was
									   	voided. However, one hardcoded exclusion was necessary
									   	based on my validation of charts for these patients. 
									   	This patient's LTC claims were voided in QicLink, but 
									   	the patient did actually stay at the facility.
04/19/2022		Joshua Manning		1) Removed subqueries in #SNF that affixed "- LTC" to the end 
									   	of a facility name on LTC claims if the facility had claims
									   	with both SNF and LTC check groups. It was causing some 
									   	provider IDs in the dimension table in the Power BI report
									   	to be duplicated, preventing a one-to-many join on stays.
									2) Incorporated new provider dimension table, adding the 
									   	formatted provider name and parent facility name to #SNF. 
									3) Added an update to #SNF to change the deprecated 
									  	Downtown Health and Rehab provider record's ID, name, and
									  	TIN to the new record's ID, name, and TIN. 
									4) Rewrote the old #FACILITIES temp table create and 
									   	inserts using QicLinkProviders.Provider_Name_Formatted 
									   	as the base. 
									5) Removed casting of patient identifiers 
									   	as NULL in #SNF. No longer necessary because LoadQicLinkData
									   	already performs the necessary updating of MRNs in the claims
									   	data. #SNF can now simply join on CLARITY.dbo.PATIENT 
									   	using the MRN in QicLinkData.
04/26/2022		Joshua Manning		1) Cleaned up code and updated step list. 
									2) Swapped positions of #ISLES and #ISLETS in the code to make
									   	the step order more logical. 
									3) Narrowed the date range condition in the join on PAT_ENC_HSP
									   	in #HOSP_VISITS to discharge dates after 14 days prior to a
									   	SNF/LTC admit and admit dates prior to 31 days after the last
									   	billed date of service on a claim. This makes it consistent
									   	with the date ranges of DISCHARGED_TO_SNF AND ADMIT_FROM_SNF,
									   	which are the only dates we currently need to capture.
04/29/2022		Joshua Manning		1) Changed #DEMO to pull from dbo.V_PATIENT to eliminate
									   	redundancy.
									2) Added a new step to eliminate stays at Parkview created from
									   	claims that had no room and board charges, only charges for
									   	PT/OT/ST. Per Tina and Tammy, these were  billed incorrectly
									   	and do not represent actual inpatient stays.
05/09/2022		Joshua Manning		Added a new column to #ISLANDS that sums PAID_AMOUNT for each
									island and a flag column named STAY_HAS_PAID_CLAIMS_YN to the
									detail table that contains "Yes" if the sum is > 0 and "No"
									otherwise. This can be used as a filter in the report to exclude
									stays that did not have any paid claim lines.
05/31/2022		Joshua Manning		Changed the length of stay calculation to use the number of units
									billed with R&B revenue codes in order to align with OMS' 
									LOS calculation method. The original calculation based on the number 
									of dates of service on all claims per stay was moved into a new
									column named TOTAL_DOS.
07/28/2022		Joshua Manning		1) Changed the length of stay calculation in step 6 to consider only
										claim lines with a paid amount > 0. This corrects an issue where
										the stay type was showing incorrectly in the Power BI report
										because the facility initially billed a patient’s stay erroneously
										as SNF and later sent a corrected claim for the stay as LTC.
									2) Removed old step 7B that cleaned up stays that were not combined
										correctly in step 7A. There have been no rows affected by this
										for the last couple of versions.
									3) Inserted new step 8 for adjusting calculated length of stay in special
										cases. Moved/renamed old step 6B as new step 8A. Added step
										8B to set LOS equal to the total dates of service on stays where
										billing errors would otherwise cause the calculated length of
										stay to be greater than the total distinct dates of service.
									4) Added step 7E to recalculate the total paid amount and length
										of stay for stays that were merged in prior steps.
									5) Added “IPR” check group to the claims inclusion criteria in 
										order to expand the scope of the report to include inpatient
										rehabilitation stays.
02/15/2023		Joshua Manning		1) Added a new provider record for Arlington Heights Health and Rehab to
										#PARENTS. The facility was bought by a different company, which began
										billing under their own NPI/tax ID in November 2022. This necessitated
										the creation of a new provider record in QicLink, but they gave it a
										slightly different name. The new row in #PARENTS aligns the two names
										to ensure that newer claims for AHHR will be grouped together with
										older ones in the Power BI report.
									2) Prepared a change to the exception criteria for length of stay
										calculations in step 8. Some claims in November 2022 had a new
										remark code on unpaid R&B charges that was causing those stays to
										have an LOS = 0.

********************************************************************************/

/* Step 1) Create temp tables for lists of parent facility names and SNF/LTC inpatient billing codes */

-- Parent facility names

IF OBJECT_ID(N'tempdb..#PARENTS', N'U') IS NOT NULL
BEGIN DROP TABLE #PARENTS PRINT 'Dropped table #PARENTS' END
ELSE PRINT 'Tried to drop table #PARENTS, but it did not exist.';

CREATE TABLE #PARENTS(
	Provider_Sequence VARCHAR(255),
	Parent_Facility VARCHAR(255),
	Provider_Name_Formatted VARCHAR(255)
)

INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6101','Arlington Heights Health And Rehab','Arlington Heights Health And Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6102','Arlington Heights Health And Rehab','Arlington Heights Health And Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('7569','Arlington Heights Health And Rehab','Arlington Heights Health And Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5902','Bishop Davies Nursing Center','Bishop Davies Nursing Center - LTC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5820','Bishop Davies Nursing Center','Bishop Davies Nursing Center - SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6661','Brentwood Place III','Brentwood Place III');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6193','Cedar Hill Healthcare Center','Cedar Hill Healthcare Center');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5866','Cityview Nursing And Rehabilitation Center','Cityview Nursing And Rehabilitation Center');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('3122','Diversicare Estates, LLC','Diversicare Estates, LLC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6495','DFW Nursing & Rehab','DFW Nursing & Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6787','DFW Nursing & Rehab','DFW Nursing & Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5889','DFW Nursing & Rehab','DFW Nursing & Rehab LTC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5717','Downtown Health and Rehabilitation','Downtown Health-LTC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('4621','Downtown Health and Rehabilitation','Downtown Health-SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6921','Fanning County Hospital Authority','Fanning County Hospital Authority');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6199','Fort Worth Transitional Care Center','Fort Worth Transitional Care Center');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6960','Interlochen Health And Rehab','Interlochen Health And Rehab LTC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5775','Interlochen Health And Rehab','Interlochen Health And Rehab SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('3252','Kindred Hospital Tarrant County','Kindred Hospital Fort Worth');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('3297','Kindred Hospital Tarrant County','Kindred Hospital-Tarrant County');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6124','LTHC Solutions','LTHC Solutions');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5857','Parkview Care Center','Parkview Care Center - LTC');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5759','Parkview Care Center','Parkview Care Center - SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6401','Remarkable Healthcare of Fort Worth','Remarkable Healthcare of Fort Worth');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6403','Richland Hills Rehabilitation And Healthcare','Richland Hills Rehabilitation And Healthcare');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5855','Ridgmar Medical Lodge - SNF','Ridgmar Medical Lodge - SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5194','Texas Rehabilitation Hospital','Texas Rehabilitation Hospital');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6195','The Meadows Health & Rehab','The Meadows Health & Rehab');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('5956','Weatherford Healthcare Center - SNF','Weatherford Healthcare Center - SNF');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('3471','West Side Campus of Care','West Side Campus of Care');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6992','West Side Campus of Care','West Side Campus of Care');
INSERT INTO #PARENTS (Provider_Sequence,Parent_Facility,Provider_Name_Formatted) VALUES ('6593','White Settlement Nursing Center','White Settlement Nursing Center');


-- Accommodation (room and board) and skilled nursing revenue codes and CPT codes

IF OBJECT_ID(N'tempdb..#BILLING_CODES', N'U') IS NOT NULL
BEGIN DROP TABLE #BILLING_CODES PRINT 'Dropped table #BILLING_CODES' END
ELSE PRINT 'Tried to drop table #BILLING_CODES, but it did not exist.';

SELECT 	PROC_CODE = STD_CODE
	,	PROC_DESCRIPTION = CODE_NAME
	,	CODE_TYPE
	,	CODE_GROUP
	,	CODE_SUBGRP_A
	,	CODE_SUBGRP_A_TYPE
INTO #BILLING_CODES
FROM dbo.STANDARD_DEFINITIONS AS BILLING_CODES
WHERE 1=1
	AND BILLING_CODES.SOURCE_ID = 1 -- Base definitions
	AND (	-- R&B and skilled nursing revenue codes
			BILLING_CODES.CODE_TYPE = 'UB revenue code'
		AND BILLING_CODES.CODE_GROUP IN ('Accommodation (room and board) charges', 'Skilled nursing charges')
	)
	AND (
		BILLING_CODES.CODE_SUBGRP_A IN (
			'All inclusive room and board',
			'Room and Board Private (one bed)',
			'Room and Board Semi-private (two beds)',
			'Room and Board (3 and 4 beds)',
			'Room and Board Deluxe Private',
			'Subacute Care',
			'Intensive Care Unit',
			'Skilled Nursing'
		)
	)
;

-- SELECT	*
-- FROM #BILLING_CODES


/* Step 2) Get all SNF and LTC claims from arc.V_QicLinkData */

IF OBJECT_ID(N'tempdb..#SNF', N'U') IS NOT NULL
BEGIN DROP TABLE #SNF PRINT 'Dropped table #SNF' END
ELSE PRINT 'Tried to drop table #SNF, but it did not exist.';

SELECT 	CLAIMS.CHKGRP as IPA
	,	CLAIMS.TIN
	,	CLAIM_LINE_SEQ = ROW_NUMBER() OVER(PARTITION BY CLAIMS.CLAIM_NUMBER ORDER BY CLAIMS.WORKSHEET_NUMBER, CLAIMS.LINE_NUMBER, CLAIMS.LINE_DUPLICATE_COUNTER)
	,	CHARGE_ID = ROW_NUMBER() OVER(ORDER BY CLAIMS.CLAIM_NUMBER, CLAIMS.WORKSHEET_NUMBER, CLAIMS.LINE_NUMBER)
	,	CLAIMS.CLAIM_NUMBER
	,	CLAIMS.WORKSHEET_NUMBER
	,	CLAIMS.LINE_NUMBER
	,	CLAIMS.LINE_DUPLICATE_COUNTER
	,	CLAIMS.PROVIDER_ID
	,	PARENT_FACILITY = COALESCE(FACILITIES.Parent_Facility, PROVIDERS.Provider_Name_Formatted)
	,	PROVIDER_NAME = COALESCE(FACILITIES.Provider_Name_Formatted, PROVIDERS.Provider_Name_Formatted)
	,	CLAIMS.MEMBER_NUMBER
	,	PATIENT.PAT_ID
	,	PATIENT.PAT_MRN_ID
	,	PATIENT.PAT_NAME
	,	CLAIMS.LAST_NAME AS MEMBER_LAST_NAME
	,	CLAIMS.FIRST_NAME AS MEMBER_FIRST_NAME
	,	CLAIMS.BENEFIT_PLAN
	,	CAST(CLAIMS.DOS_FROM AS DATE) AS DOS_FROM
	,	CAST(CLAIMS.DOS_TO AS DATE) AS DOS_TO
	,	DATEDIFF(DAY, CLAIMS.DOS_FROM, CLAIMS.DOS_TO) + 1 as LOS
	,	CLAIMS.DX
	,	PROC_CODE = CASE
			WHEN CLAIMS.PROC_CODE LIKE 'U[0-9][0-9][0-9]'
			THEN STUFF(CLAIMS.PROC_CODE, 2, 0, '0')
			ELSE CLAIMS.PROC_CODE
			END
	,	CLAIMS.PROC_DESCRIPTION
	,	CLAIMS.UNITS
	,	CLAIMS.UNIT_RATE
	,	CLAIMS.TOTAL_CHARGES
	,	CLAIMS.PAID_AMOUNT
	,	CLAIMS.REMARK
	,	REVERSED = CASE WHEN REVERSED_CHARGES.LINE_NUMBER IS NOT NULL THEN 'Yes' ELSE 'No' END
	,	RB_CODE_YN = CASE 
			WHEN BILL_CODES.PROC_CODE IS NOT NULL 
			THEN 'Yes' 
			ELSE 'No' 
			END -- Claim line has a code that indicates the units billed = the number of bed days billed
INTO #SNF
FROM arc.V_QicLinkData AS CLAIMS
INNER JOIN ( -- There can be multiple rows in the claim detail table for a single claim line if the charge was later edited or reversed. The subsequent rows will have a LINE_COUNTER > 0.
	-- INNER JOINing on this subquery ensures that there will only be one row returned per claim line, i.e. the most recent one based on the line counter.
	SELECT	CLAIM_NUMBER
		,	WORKSHEET_NUMBER
		,	LINE_NUMBER
		,	MAX(LINE_COUNTER) as MAX_LINE_COUNTER -- The most recent version of each claim line
	FROM arc.V_QicLinkData
	GROUP BY CLAIM_NUMBER
		,	WORKSHEET_NUMBER
		,	LINE_NUMBER
) AS MAX_LINE_COUNTER ON MAX_LINE_COUNTER.CLAIM_NUMBER = CLAIMS.CLAIM_NUMBER
	AND MAX_LINE_COUNTER.WORKSHEET_NUMBER = CLAIMS.WORKSHEET_NUMBER
	AND MAX_LINE_COUNTER.LINE_NUMBER = CLAIMS.LINE_NUMBER
	AND MAX_LINE_COUNTER.MAX_LINE_COUNTER = CLAIMS.LINE_COUNTER -- Only the most recent version of each claim line
LEFT JOIN arc.V_QICLINKDATA AS REVERSED_CHARGES ON REVERSED_CHARGES.CLAIM_NUMBER = CLAIMS.CLAIM_NUMBER -- Identify reversed/voided charges
	AND REVERSED_CHARGES.WORKSHEET_NUMBER = CLAIMS.WORKSHEET_NUMBER
	AND REVERSED_CHARGES.LINE_NUMBER = CLAIMS.LINE_NUMBER
	AND REVERSED_CHARGES.LINE_DUPLICATE_COUNTER > 0 -- Claim line has a duplicate record indicating an adjustment
	AND REVERSED_CHARGES.UNITS < 0 -- Negative adjustment
	AND REVERSED_CHARGES.CLAIM_NUMBER <> 20656624 -- Hardcoded exclusion based on manual chart audit. Patient's LTC claims were voided in QicLink, but the patient did actually stay at the facility. OMS just didn't pay for it.
LEFT JOIN #PARENTS AS FACILITIES ON FACILITIES.Provider_Sequence = CLAIMS.PROVIDER_ID
LEFT JOIN arc.QicLinkProviders as PROVIDERS ON PROVIDERS.Provider_Sequence = CLAIMS.PROVIDER_ID
LEFT JOIN CLARITY.dbo.PATIENT ON PATIENT.PAT_MRN_ID = CLAIMS.MEMBER_NUMBER
LEFT JOIN #BILLING_CODES AS BILL_CODES ON BILL_CODES.PROC_CODE = CASE
	WHEN CLAIMS.PROC_CODE LIKE 'U[0-9][0-9][0-9]'	-- Needed because some UB revenue codes are missing the first zero
	THEN STUFF(CLAIMS.PROC_CODE, 2, 0, '0') -- Insert a zero after the 'U' if a revenue code only has three digits after the 'U'
	ELSE CLAIMS.PROC_CODE
	END
WHERE 1=1
	AND CLAIMS.CHKGRP IN ('SNF', 'LTC', 'IPR')
	-- AND DOS_FROM >= @START -- JSM 2022-01-10 See comment on variable declaration above
	-- AND CLAIMS.DOS_FROM <= @END -- JSM 2022-03-30 See comment on variable declaration above
	AND CLAIMS.MEMBER_NUMBER NOT IN ('0000', '00001' ) -- MEMBER, NOT FOUND and NOT FOUND, MEMBER
	AND (
		CLAIMS.REMARK IS NULL
		OR CLAIMS.REMARK NOT IN (
			'Duplicate claim',
			'Duplicate of charges previously processed'
		)
	)
	AND REVERSED_CHARGES.LINE_NUMBER IS NULL -- Exclude reversed/voided charges
;

-- SELECT	*
-- FROM #SNF
-- WHERE 1=1
-- 	-- AND CLAIM_NUMBER = ''


/* Step 3) Make manual corrections to provider information */

/* Step 3A) Change provider ID for deprecated Downtown Health and Rehab claims to the new Downtown Health-SNF record */

UPDATE #SNF
SET   PROVIDER_ID = 4621 -- DOWNTOWN HEALTH-SNF
	, PROVIDER_NAME = 'Downtown Health-SNF'
	, TIN = 461353294
WHERE PROVIDER_ID = 3142 -- DOWNTOWN HEALTH AND REHABILITATION
;


/* Step 3B) Align names of duplicate provider records for Kindred Hospital - Tarrant County */

UPDATE #SNF
SET	PROVIDER_NAME = 'Kindred Hospital-Tarrant County'
WHERE PROVIDER_NAME = 'Kindred Hospital Fort Worth'
;


/* Step 3C) Remove voided claim line duplicates for one claim in QicLink based on manual chart audit. Patient's LTC claims were voided in QicLink, but the patient did actually stay at the facility. OMS just didn't pay for it. */

DELETE FROM #SNF	-- Remove the claim lines with negative charges but leave the lines with positive charges
WHERE CLAIM_NUMBER = 20656624
	AND UNITS < 0
;

UPDATE #SNF		
SET PAID_AMOUNT = 0 -- Change paid amount to 0 so that it will be flagged later as STAY_HAS_PAID_CLAIMS_YN = 'No'
WHERE CLAIM_NUMBER = 20656624
;

-- SELECT	
-- 		*
-- 		-- DISTINCT PROC_CODE, PROC_DESCRIPTION
-- FROM #SNF
-- WHERE 1=1
-- 	-- AND MBR_NUMBER = ''
-- 	AND IPA = 'IPR'
-- ORDER BY CLAIM_NUMBER, CLAIM_LINE_SEQ
-- ;


/* Step 4) Correct the dates of service on claims with a single date of service and multiple billed bed days */

IF OBJECT_ID(N'tempdb..#SINGLE_DOS', N'U') IS NOT NULL
BEGIN DROP TABLE #SINGLE_DOS PRINT 'Dropped table #SINGLE_DOS' END
ELSE PRINT 'Tried to drop table #SINGLE_DOS, but it did not exist.';

SELECT	SNF.CHARGE_ID
	,	SNF.IPA
	,	SNF.TIN
	,	SNF.PROVIDER_ID
	,	SNF.PARENT_FACILITY
	,	SNF.PROVIDER_NAME
	,	SNF.MEMBER_NUMBER
	,	SNF.PAT_ID
	,	SNF.PAT_MRN_ID
	,	SNF.PAT_NAME
	,	SNF.MEMBER_LAST_NAME
	,	SNF.MEMBER_FIRST_NAME
	,	SNF.BENEFIT_PLAN
	,	SNF.CLAIM_NUMBER
	,	SNF.WORKSHEET_NUMBER
	,	SNF.LINE_NUMBER
	,	SNF.DOS_FROM
	,	ORIGINAL_DOS_TO = SNF.DOS_TO
	,	DOS_TO = DATEADD(DAY, CAST(SNF.UNITS AS INT) - 1, SNF.DOS_TO)
	,	LOS = CAST(SNF.UNITS AS INT)
	,	SNF.UNITS
	,	SNF.UNIT_RATE
	,	SNF.PROC_CODE
	,	SNF.PROC_DESCRIPTION
	,	SNF.REMARK
INTO #SINGLE_DOS
FROM #SNF AS SNF
INNER JOIN #BILLING_CODES AS CODES ON CODES.PROC_CODE = SNF.PROC_CODE
WHERE 1=1
	AND SNF.DOS_FROM = SNF.DOS_TO
	AND CAST(SNF.UNITS AS INT) > 1
	AND (
		REMARK IS NULL OR
		REMARK NOT IN (
			'Date range not valid with units submitted',
			'Duplicate of charges previously processed'
		)
	)
;

-- SELECT	*
-- -- FROM #SNF AS DOS
-- from #SINGLE_DOS
-- WHERE 1=1
-- 	-- AND MBR_NUMBER = ''
-- 	-- AND CHKGRP IN ('SNF', 'LTC')
-- 	-- AND CLAIM_NUMBER IN (
-- 	-- )
-- ORDER BY MEMBER_LAST_NAME, MEMBER_FIRST_NAME, MEMBER_NUMBER, DOS_FROM, DOS_TO


-- Update the DOS_TO and LOS of single DOS claims using the corrections in #SINGLE_DOS

UPDATE #SNF
SET 	DOS_TO = TBL.DOS_TO
	,	LOS = TBL.LOS
FROM (
	SELECT	CHARGE_ID
		,	MIN(DOS_FROM) AS DOS_FROM
		,	MAX(DOS_TO) AS DOS_TO
		,	MAX(LOS) AS LOS
	FROM #SINGLE_DOS
	GROUP BY CHARGE_ID
) AS TBL
WHERE 1=1
	AND #SNF.CHARGE_ID = TBL.CHARGE_ID
;

/* Get current MRNs by matching member numbers in QicLink data to MRNs in CLARITY.dbo.IDENTITY_ID_HX */
/*** JSM 2022-04-05 - Removed this step because the arc.LoadQicLinkData stored procedure already updates the MRNs using this logic  ***/


/* Step 5) Correct the dates of service on claims for LTHC Solutions, which have only a single DOS apiece and are showing up as separate stays */

IF OBJECT_ID(N'tempdb..#LTHC', N'U') IS NOT NULL
BEGIN DROP TABLE #LTHC PRINT 'Dropped table #LTHC' END
ELSE PRINT 'Tried to drop table #LTHC, but it did not exist.';

SELECT  CHARGE_ID
	,	PAT_MRN_ID
	,	CLAIM_NUMBER
	,	CLAIM_LINE_SEQ
	,	DOS_FROM
	,	DOS_TO
	,	LEAD(DOS_FROM) OVER(PARTITION BY PAT_MRN_ID ORDER BY DOS_FROM) AS NEXT_DOS_FROM
INTO #LTHC
FROM #SNF
WHERE 1=1
	AND PROVIDER_NAME = 'LTHC SOLUTIONS'
	AND PAT_MRN_ID = '34808675'	-- This issue occurs for only one patient and stay. Right now I can't think of a way to make this work dynamically to accommodate potential future cases, so I'm hardcoding this query for the one case that currently exists so that it doesn't affect anyone else later. It will break if the current MRN gets merged; however, the potential impact of this is very low because this provider only has one associated patient/stay. -- JSM 2022-03-30
	AND DOS_FROM >= '2020-04-10'
	AND DOS_FROM <= '2020-06-24'
;

-- SELECT	*
-- FROM #LTHC


/* Update DOS_TO of LTHC claims in #SNF */

UPDATE #SNF
SET 	DOS_TO = CASE
			WHEN LTHC.NEXT_DOS_FROM = LTHC.DOS_FROM -- If the current row's DOS_FROM = the next row's DOS_FROM
			THEN LTHC.DOS_FROM -- Set the DOS_TO equal to the DOS_FROM
			WHEN LTHC.NEXT_DOS_FROM IS NULL THEN #SNF.DOS_TO -- If this is the last claim/line, keep the original DOS_TO
			ELSE DATEADD(DAY, -1, LTHC.NEXT_DOS_FROM) -- Otherwise, set the DOS_TO of the current row to the date before the next row's DOS_FROM so that each row's dates of service are contiguous
			END
	,	LOS = CASE
			WHEN LTHC.NEXT_DOS_FROM IS NULL
			THEN #SNF.LOS
			ELSE DATEDIFF(DAY, #SNF.DOS_FROM, CASE WHEN LTHC.NEXT_DOS_FROM = LTHC.DOS_FROM THEN LTHC.DOS_FROM ELSE DATEADD(DAY, -1, LTHC.NEXT_DOS_FROM) END) + 1
		END
-- OUTPUT INSERTED.*
FROM #LTHC AS LTHC
WHERE LTHC.CLAIM_NUMBER = #SNF.CLAIM_NUMBER
;


/* Step 6) Group claim lines into stays and calculate length of stay based on the number of units billed with R&B revenue/CPT codes */

/* Step 6A) Apply gaps and islands logic to identify related claims for the same patient and facility with adjacent or overlapping dates of service */

IF OBJECT_ID(N'tempdb..#ISLANDS', N'U') IS NOT NULL
BEGIN DROP TABLE #ISLANDS PRINT 'Dropped table #ISLANDS' END
ELSE PRINT 'Tried to drop table #ISLANDS, but it did not exist.';

WITH SETUP AS ( -- Get relevant fields from the staging table
	SELECT	PAT_ID
		,	PAT_MRN_ID
		,	PAT_NAME
		,	CHARGE_ID -- Uniquely identifies a particular claim line; a surrogate key for the claim data's natural composite key (claim number + worksheet number + line number)
		,	CLAIM_NUMBER
		,	PROVIDER_NAME
		,	DOS_FROM
		,	DOS_TO
		,	PAID_AMOUNT
		,	UNITS
		,	PROC_CODE
		,	PROC_DESCRIPTION
		,	REMARK
		,	RB_CODE_YN
	FROM #SNF AS STAGING
),
GROUPS AS (  -- Do a row number for each patient and identify the previous start and end date for each claim line
	SELECT	PAT_MRN_ID
		,	PAT_ID
		,	PAT_NAME
		,	CHARGE_ID
		,	CLAIM_NUMBER
		,	PROVIDER_NAME
		,	DOS_FROM
		,	DOS_TO
		,	PAID_AMOUNT
		,	UNITS
		,	PROC_CODE
		,	PROC_DESCRIPTION
		,	REMARK
		,	RB_CODE_YN
		,	RN = ROW_NUMBER() OVER(PARTITION BY PAT_MRN_ID, PROVIDER_NAME ORDER BY DOS_FROM, DOS_TO) -- Number the rows for each patient
		,	PREV_START_DATE = LAG(DOS_FROM, 1) OVER (PARTITION BY PAT_MRN_ID, PROVIDER_NAME ORDER BY DOS_FROM, DOS_TO) -- Get the previous start date
		,	PREV_END_DATE = LAG(DOS_TO, 1) OVER (PARTITION BY PAT_MRN_ID, PROVIDER_NAME ORDER BY DOS_FROM, DOS_TO) -- Get the previous end date
	FROM SETUP
),
ISLANDS AS ( -- Assign a unique ID to each stay per patient ("islands")
    SELECT	GROUPS.*
		,	ISLAND_ID = SUM(CASE
				WHEN GROUPS.DOS_FROM >= PREV_START_DATE AND GROUPS.DOS_FROM <= DATEADD(DAY, 1, PREV_END_DATE) -- If any of the current row's dates of service either overlap with previous row's dates of service or are the day after the previous row's end date...
					OR GROUPS.DOS_TO >= PREV_START_DATE AND GROUPS.DOS_TO <= DATEADD(DAY, 1, PREV_END_DATE)
				THEN 0 -- Then the current row is part of the same stay as the previous row, so don't increment the ISLAND_ID.
				ELSE 1 -- Otherwise, the current row represents a separate stay, so increment ISLAND_ID by +1
				END
			) OVER (ORDER BY PAT_MRN_ID, PROVIDER_NAME, GROUPS.RN)
			-- ISLAND_ID uses SUM as a window function to create a running total that acts like a DENSE_RANK. It increases by 1 each time a new island starts. The case statement identifies when a new island begins by checking whether the previous row's end date occurs on or after the day before the current row's start date. If true, then there is no gap between the claims, and the second row's ISLAND_ID stays the same as previous row's ISLAND_ID. If neither of those are true, i.e. there is a gap between the first claim's last DOS and the next claim's first DOS, then ISLAND_ID increases by 1 to indicate the start of a new island.
			-- 2021-11-30 JSM: Unfortunately, this method produces incorrect results in cases where there is an initial claim for a stay with the full date range followed by 2 or more claims with dates of service inside the full date range (example: original claim was 8/1/20 - 10/30/20, claim 2 was only for 9/1/20 and claim 3 was only for 9/23/20). Neither the DOS_FROM nor DOS_TO of claim 3 will be <= DATEADD(DAY, 1, PREV_END_DATE) of claim 2, so claim 3 will have a separate island ID. I could not figure out a way to fix this here, so I added UPDATE statements below to fix the problems.
    FROM GROUPS
),
ISLAND_DATES AS (
	SELECT	-- Get the earliest DOS and latest DOS for each island
			ISLAND_ID AS SNF_STAY_ID
		,	CHARGE_ID
		,	CLAIM_NUMBER
		,	PAT_ID
		,	PAT_MRN_ID
		,	PAT_NAME
		,	PROVIDER_NAME
		,	DOS_FROM
		,	DOS_TO
		,	PROC_CODE
		,	PROC_DESCRIPTION
		,	UNITS
		,	REMARK
		,	PAID_AMOUNT
		,	RB_CODE_YN
		,	MIN(DOS_FROM) OVER(PARTITION BY ISLAND_ID) AS STAY_BEGIN_DATE
		,	MAX(DOS_TO) OVER(PARTITION BY ISLAND_ID) AS STAY_END_DATE
		,	SUM(PAID_AMOUNT) OVER(PARTITION BY ISLAND_ID) AS TOTAL_PAID_AMOUNT
		,	MAX(RB_CODE_YN) OVER(PARTITION BY ISLAND_ID) AS STAY_HAS_RB_CODES_YN
		,	SUM(CASE 
				WHEN RB_CODE_YN = 'Yes' 
					AND (	-- Some stays had claim lines that were originally billed with invalid dates of service and then rebilled with corrected dates of service. This condition on REMARK prevents double counting the units billed by excluding the original invalid claim line.
							REMARK IS NULL
						OR 	REMARK <> 'Date range not valid with units submitted'
					)
				THEN UNITS
				ELSE 0 
				END
			) OVER(PARTITION BY ISLAND_ID) AS OLD_LENGTH_OF_STAY
		,	SUM(CASE 
				WHEN RB_CODE_YN = 'Yes' 
					AND PAID_AMOUNT > 0
				THEN UNITS
				ELSE 0 
				END
			) OVER(PARTITION BY ISLAND_ID) AS LENGTH_OF_STAY
	FROM ISLANDS
	-- WHERE ISLAND_ID = 310
)
SELECT 	ISLAND_DATES.*
	-- ,	SNF_STAY_ID = ISLAND_ID
	,	TOTAL_DOS = DATEDIFF(DAY, STAY_BEGIN_DATE, STAY_END_DATE) + 1
	,	STAY_HAS_PAID_CLAIMS_YN = CASE	-- Flag stays that only include unpaid claims. User will exclude these as desired from within the Power BI report. -- JSM 2022-05-09
			WHEN ISLAND_DATES.TOTAL_PAID_AMOUNT > 0
			THEN 'Yes'
			ELSE 'No'
			END
INTO #ISLANDS
FROM ISLAND_DATES
ORDER BY
		PAT_NAME
	,	PAT_ID
	,	PAT_MRN_ID
	,	STAY_BEGIN_DATE
;

-- SELECT	
-- 		*
-- FROM #ISLANDS
-- WHERE 1=1
-- 	-- AND PAT_MRN_ID = 7195845
-- 	and SNF_STAY_ID = 310
-- -- GROUP BY ISLAND_ID
-- ORDER BY PAT_NAME, PAT_MRN_ID, SNF_STAY_ID, CLAIM_NUMBER, CHARGE_ID


-- Get total days difference and average days difference per stay

-- SELECT AVG(TOTAL_DAYS_DIFF) AS AVG_DAYS_DIFF	-- 9.551 days
	-- ,	SUM(TOTAL_DAYS_DIFF) AS TOTAL_DAYS_DIFF -- 1,490 days
-- FROM(
-- SELECT	
-- 		-- *
-- 		-- DISTINCT
-- 		ISLAND_ID
-- 	-- ,	SUM(OLD_LENGTH_OF_STAY) - SUM(LENGTH_OF_STAY) AS TOTAL_DAYS_DIFF
-- 	,	MAX(OLD_LENGTH_OF_STAY - LENGTH_OF_STAY) AS TOTAL_DAYS_DIFF
-- FROM #ISLANDS
-- WHERE 1=1
-- 	-- AND PAT_MRN_ID = 7195845
-- GROUP BY ISLAND_ID
-- -- ORDER BY PAT_NAME, PAT_MRN_ID, SNF_STAY_ID, CLAIM_NUMBER, CHARGE_ID
-- ) AS TBL


-- IF OBJECT_ID(N'tempdb..#ZERO_LOS', N'U') IS NOT NULL
-- BEGIN DROP TABLE #ZERO_LOS PRINT 'Dropped table #ZERO_LOS' END
-- ELSE PRINT 'Tried to drop table #ZERO_LOS, but it did not exist.';

-- SELECT	*
-- into #zero_los
-- FROM #ISLANDS
-- WHERE 1=1
-- 	-- AND PAT_MRN_ID = ''
-- 	and LENGTH_OF_STAY = 0
-- 	-- AND PROC_CODE IN ('U0110', 'U0120', 'U120')
-- ORDER BY PAT_NAME, PAT_MRN_ID, SNF_STAY_ID

-- SELECT	
-- 		ZERO.ISLAND_ID
-- 	,	ZERO.TOTAL_PAID_AMOUNT
-- 	,	ZERO.TOTAL_DOS
-- 	,	ZERO.STAY_HAS_PAID_CLAIMS_YN
-- 	,	SNF.*
-- 	-- 	DISTINCT
-- 	-- 	SNF.CLAIM_NUMBER
-- 	-- ,	REMARK
-- FROM #SNF AS SNF
-- INNER JOIN #ZERO_LOS AS ZERO ON ZERO.CHARGE_ID = SNF.CHARGE_ID
-- WHERE 1=1
-- 	AND SNF.CLAIM_NUMBER IN (
-- 		SELECT DISTINCT CLAIM_NUMBER 
-- 		FROM #zero_los 
-- 		WHERE 1=1
-- 			-- AND STAY_HAS_PAID_CLAIMS_YN = 'No'
-- 			AND STAY_HAS_PAID_CLAIMS_YN = 'Yes'
-- 	)
-- ORDER BY SNF.PAT_NAME, SNF.PAT_MRN_ID, SNF_STAY_ID, SNF.CLAIM_NUMBER, CLAIM_LINE_SEQ


/* Notes on zero LOS stays using units of R&B codes billed
1) Claim # 20477432, memberNo 51338545, HERVEY,BEVERLY ELAINE; Parkview Care Center - LTC, 2020-04-16 thru 2020-04-18
	Remark code on both claim lines says duplicate of charges previously processed, but there are no other SNF/LTC claims in #SNF for this member.
2) Claim # 22156580, memberNo 37120953, COTTON,JEFF; Parkview Care Center - SNF, 2022-03-17 and 2022-04-01 thru 2022-04-21
	First claim has remark of 'Date range not valid with units submitted'. Second claim has remark 'Resubmit with days or units of service'. Both have R&B rev code U0120, but the first claim has RB_CODE_YN = 'No' because of its remark while the second has 'Yes' because that remark is not in the exception list. Should it be? Should this be included in LOS calculations if STAY_HAS_PAID_CLAIMS_YN is not 'Yes'?
3) Claim # 22232296, memberNo 8473837, EASTERLING,DEIDRA F; Parkview Care Center - SNF, 2022-04-26 thru 2022-04-30
	R&B claim line has only one DOS and remark of date range not valid. Should this be included in LOS calculations if STAY_HAS_PAID_CLAIMS_YN is not 'Yes'?
*/


/* Step 7) Correct cases where a single stay was incorrectly split into multiple stays */

/* Step 7A) Get instances where a single stay was incorrectly split into multiple stays due to the initial claim having the full date range and two or more subsequent claims having dates of service within the full range */

IF OBJECT_ID(N'tempdb..#ISLES', N'U') IS NOT NULL
BEGIN DROP TABLE #ISLES PRINT 'Dropped table #ISLES' END
ELSE PRINT 'Tried to drop table #ISLES, but it did not exist.';

SELECT 	DISTINCT
		ISLANDS.*
	,	ISLES.SNF_STAY_ID AS ISLE_SNF_STAY_ID
	,	ISLES.STAY_BEGIN_DATE AS ISLE_STAY_BEGIN_DATE
	,	ISLES.STAY_END_DATE AS ISLE_STAY_END_DATE
	,	ISLES.CHARGE_ID AS ISLE_CHARGE_ID
	,	ISLES.PAID_AMOUNT AS ISLE_PAID_AMOUNT
	,	ISLES.TOTAL_PAID_AMOUNT AS ISLE_TOTAL_PAID_AMOUNT
	, 	ISLES.LENGTH_OF_STAY AS ISLE_LENGTH_OF_STAY
INTO #ISLES
FROM #ISLANDS AS ISLANDS
INNER JOIN #ISLANDS AS ISLES ON ISLES.SNF_STAY_ID = ISLANDS.SNF_STAY_ID + 1
	AND	ISLES.PAT_ID = ISLANDS.PAT_ID
	AND ISLES.PROVIDER_NAME = ISLANDS.PROVIDER_NAME
	AND ISLES.STAY_BEGIN_DATE <= DATEADD(DAY, 1, ISLANDS.STAY_END_DATE)
;

-- SELECT	#ISLES.*
-- FROM #ISLES
-- ORDER BY PAT_NAME, PAT_MRN_ID, DOS_FROM


/* Potential resolutions of issues where calculated LOS > total dates of service
	1.	Where multiple lines on a single claim have the same dates of service and procedure but different units and paid amounts, use the most recently entered or paid. (Need to bring in paid date and date claim entered fields) Example: claim number 20655839 worksheets 1 and 3
	2.	Ignore lines that have only one date of service but multiple units. Example: claim number 19514291 worksheet number 1 (there is something funky about this line. in V_QIC_LINK_DATA its DOS_TO is 2019-08-31 but in #SNF it is showing 2019-09-30)
	3. Set length of stay = total dates of service
*/

-- SELECT	#SNF.*
-- 	,	#ISLES.*
-- FROM #SNF
-- INNER JOIN #ISLES ON #ISLES.PAT_MRN_ID = #SNF.PAT_MRN_ID
-- ORDER BY #SNF.PAT_NAME, #SNF.PAT_MRN_ID, #SNF.DOS_FROM


/* 7B) Correct the stay end date of the first part of the stay to be the actual end date */

UPDATE #ISLANDS
SET STAY_END_DATE = #ISLES.ISLE_STAY_END_DATE
-- OUTPUT INSERTED.*
FROM #ISLES
WHERE #ISLANDS.SNF_STAY_ID = #ISLES.SNF_STAY_ID
;


/* 7C) Correct the stay begin date of the second part of the stay to be the actual begin date */

UPDATE #ISLANDS
SET STAY_BEGIN_DATE = #ISLES.STAY_BEGIN_DATE
-- OUTPUT INSERTED.*
FROM #ISLES
WHERE #ISLANDS.SNF_STAY_ID = #ISLES.ISLE_SNF_STAY_ID
;


/* 7D) Correct the SNF stay of the second part of the stay to be the SNF stay ID of the first part of the stay */

UPDATE #ISLANDS
SET SNF_STAY_ID = #ISLES.SNF_STAY_ID
-- OUTPUT INSERTED.*
FROM #ISLES
WHERE #ISLANDS.SNF_STAY_ID = #ISLES.ISLE_SNF_STAY_ID
;


/* 7E) Recalculate the total paid amount and length of stay for the isles that were merged in the above update statements */

UPDATE #ISLANDS
SET 	TOTAL_PAID_AMOUNT = ISLANDS.TOTAL_PAID_AMOUNT
	,	LENGTH_OF_STAY = ISLANDS.LENGTH_OF_STAY
	,	STAY_HAS_RB_CODES_YN = ISLANDS.STAY_HAS_RB_CODES_YN
	,	STAY_HAS_PAID_CLAIMS_YN = CASE
			WHEN ISLANDS.TOTAL_PAID_AMOUNT > 0
			THEN 'Yes'
			ELSE 'No'
			END
-- OUTPUT INSERTED.*
FROM (
	SELECT	PAT_ID
		,	PROVIDER_NAME
		,	STAY_BEGIN_DATE
		,	SNF_STAY_ID
		,	SUM(PAID_AMOUNT) OVER(PARTITION BY SNF_STAY_ID) AS TOTAL_PAID_AMOUNT
		,	MAX(RB_CODE_YN) OVER(PARTITION BY SNF_STAY_ID) AS STAY_HAS_RB_CODES_YN
		,	SUM(CASE 
				WHEN RB_CODE_YN = 'Yes' 
					AND PAID_AMOUNT > 0
				THEN UNITS
				ELSE 0 
				END
			) OVER(PARTITION BY SNF_STAY_ID) AS LENGTH_OF_STAY
	FROM #ISLANDS
) AS ISLANDS
WHERE ISLANDS.SNF_STAY_ID = #ISLANDS.SNF_STAY_ID
;

-- SELECT	*
-- 	,	DAYS_DIFF = LENGTH_OF_STAY - TOTAL_DOS
-- FROM #ISLANDS
-- WHERE 1=1
-- 	-- AND LENGTH_OF_STAY > TOTAL_DOS
-- 	-- AND STAY_HAS_PAID_CLAIMS_YN = 'YES'
-- 	-- and PAID_AMOUNT = 0


-- /* Step 7B) Get instances where a single stay was incorrectly split into multiple stays for a reason other than having an initial claim for a stay with the full date range followed by 2 or more claims with dates of service inside the full date range */

-- IF OBJECT_ID(N'tempdb..#ISLETS', N'U') IS NOT NULL
-- BEGIN DROP TABLE #ISLETS PRINT 'Dropped table #ISLETS' END
-- ELSE PRINT 'Tried to drop table #ISLETS, but it did not exist.';

-- SELECT 	ISLANDS.*
-- 	,	ISLETS.SNF_STAY_ID AS ISLE_SNF_STAY_ID
-- 	,	ISLETS.STAY_BEGIN_DATE AS ISLE_STAY_BEGIN_DATE
-- 	,	ISLETS.STAY_END_DATE AS ISLE_STAY_END_DATE
-- INTO #ISLETS
-- FROM #ISLANDS AS ISLANDS
-- INNER JOIN #ISLANDS AS ISLETS ON ISLETS.SNF_STAY_ID > ISLANDS.SNF_STAY_ID
-- 	AND ISLETS.PAT_ID = ISLANDS.PAT_ID
-- 	AND ISLETS.PROVIDER_NAME = ISLANDS.PROVIDER_NAME
-- 	AND (
-- 		ISLETS.STAY_END_DATE >= ISLANDS.STAY_BEGIN_DATE AND ISLETS.STAY_BEGIN_DATE <= ISLANDS.STAY_END_DATE -- If any of the current row's dates of service are within the previous row's dates of service or on the day after the previous row's end date
-- 	)
-- ;

-- -- SELECT	*
-- -- FROM #ISLETS


-- /* Correct the stay end date of the first part of the stay to be the actual end date */

-- UPDATE #ISLANDS
-- SET STAY_END_DATE = #ISLETS.ISLE_STAY_END_DATE
-- -- OUTPUT INSERTED.*
-- FROM #ISLETS
-- WHERE #ISLANDS.SNF_STAY_ID = #ISLETS.SNF_STAY_ID
-- ;


-- /* Correct the stay begin date of the second part of the stay to be the actual begin date */

-- UPDATE #ISLANDS
-- SET STAY_BEGIN_DATE = #ISLETS.STAY_BEGIN_DATE
-- -- OUTPUT INSERTED.*
-- FROM #ISLETS
-- WHERE #ISLANDS.SNF_STAY_ID = #ISLETS.ISLE_SNF_STAY_ID
-- ;


-- /* Correct the SNF stay of the second part of the stay to be the SNF stay ID of the first part of the stay */

-- UPDATE #ISLANDS
-- SET SNF_STAY_ID = #ISLETS.SNF_STAY_ID
-- -- OUTPUT INSERTED.*
-- FROM #ISLETS
-- WHERE #ISLANDS.SNF_STAY_ID = #ISLETS.ISLE_SNF_STAY_ID
-- ;


/* Step 8) Adjust length of stay in special cases */

/* Step 8A) Change length of stay to units if the only R&B codes in the stay had a remark of 'Date range not valid with units submitted' */

UPDATE #ISLANDS
SET LENGTH_OF_STAY = LOS.LENGTH_OF_STAY
FROM (
	SELECT 	ISLANDS.SNF_STAY_ID
		,	LENGTH_OF_STAY = SUM(UNITS)
	FROM #ISLANDS AS ISLANDS
	INNER JOIN #BILLING_CODES AS CODES ON CODES.PROC_CODE = ISLANDS.PROC_CODE
	WHERE 1=1
		AND ISLANDS.LENGTH_OF_STAY = 0
		AND STAY_HAS_PAID_CLAIMS_YN = 'No'
		AND REMARK = 'Date range not valid with units submitted'	-- Being considered for replacement with the criteria below in v2.5
		-- AND REMARK IN (
		-- 	'Date range not valid with units submitted',
		-- 	'No contract for this provider on date of service'	-- May be added in v2.5 to account for some claims where both of these remarks were the only ones on R&B codes in the stay. In these cases, the LOS should default to the billed bed days to prevent the stays from showing up as LOS = 0. 2023-02-16 JSM
		-- )
	GROUP BY ISLANDS.SNF_STAY_ID
) AS LOS
WHERE LOS.SNF_STAY_ID = #ISLANDS.SNF_STAY_ID
;


/* 8B) In cases where the length of stay is greater than the total dates of service in the stay due to multiple paid charges for the same dates of service, change the length of stay to the total dates of service */

UPDATE #ISLANDS
SET LENGTH_OF_STAY = TOTAL_DOS
-- OUTPUT inserted.*
WHERE LENGTH_OF_STAY > TOTAL_DOS
;


/* Step 9) Remove stays at Parkview that did not have any inpatient charges with room and board (accommodation) revenue codes. Per Tina Whitfield and Tammy Boozer, these were billed incorrectly and do not represent inpatient stays. */

DELETE FROM #ISLANDS
-- OUTPUT deleted.*
WHERE PROVIDER_NAME LIKE 'PARKVIEW%'
	AND STAY_HAS_PAID_CLAIMS_YN = 'No'
	AND STAY_HAS_RB_CODES_YN = 'No'
;


/* Step 10) Get demographics and care team information for patients in SNF data pull */

IF OBJECT_ID(N'tempdb..#DEMO', N'U') IS NOT NULL
BEGIN DROP TABLE #DEMO PRINT 'Dropped table #DEMO' END
ELSE PRINT 'Tried to drop table #DEMO, but it did not exist.';

SELECT	SNF.PAT_ID
	,	SNF.PAT_NAME
	,	BIRTH_DATE
	,	AGE
	,	SEX
	,	RACE
	,	ETHNIC_GROUP
	,	RACE_ETHNICITY
	,	[LANGUAGE]
	,	CITY
	,	COUNTY
	,	STATE
	,	ZIP_CODE
	,	TARRANT_ZIP
	,	PCP_PROV_ID
	,	PCP_PROV_NAME
	,	PCP_PROV_NPI
	,	PCP_PROV_SERVICE_LINE
	,	PCP_PROV_SPECIALTY
	,	PCP_PROV_SPECIALTY_GROUPER
	,	EMPANELED_PCP_YN
	,	PCP_MED_HOME
	,	PAT_MED_HOME
INTO #DEMO
FROM (SELECT DISTINCT PAT_ID, PAT_NAME FROM #SNF) AS SNF
INNER JOIN dbo.V_PATIENT ON V_PATIENT.PAT_ID = SNF.PAT_ID
;

-- SELECT	*
-- FROM #DEMO
-- WHERE 1=1
-- 	-- AND PCP_PROV_NAME IS NULL
-- ORDER BY PAT_NAME
-- ;


/* Step 11) Get all hospital encounters for patients in SNF data pull from 14 days prior to SNF entry to 30 days after SNF discharge */

IF OBJECT_ID(N'tempdb..#HOSP_VISITS', N'U') IS NOT NULL
BEGIN DROP TABLE #HOSP_VISITS PRINT 'Dropped table #HOSP_VISITS' END
ELSE PRINT 'Tried to drop table #HOSP_VISITS, but it did not exist.';

SELECT	SNF.PAT_ID
	,	SNF.PAT_MRN_ID
	,	SNF.PAT_NAME
	,	SNF.SNF_STAY_ID
	,	STAY_BEGIN_DATE
	,	STAY_END_DATE
	,	PAT_ENC_HSP.PAT_ENC_CSN_ID
	,	PAT_ENC_HSP.HSP_ACCOUNT_ID
	,	PAT_ENC_HSP.HOSP_ADMSN_TIME
	,	PAT_ENC_HSP.INP_ADM_DATE
	,	PAT_ENC_HSP.HOSP_DISCH_TIME
	,	HOSP_ADMSN_DATE = CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE)
	,	HOSP_DISCH_DATE = CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE)
	-- JSM 2022-01-26 Commenting out calculated columns below because, at this time, the customer is only interested in the discharge immediately prior to a post-acute care facility stay and any admissions that occurred while the patient was staying at the facility.
	-- ,	PRIOR_TO_SNF = CASE
	-- 		WHEN 	CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE) >= DATEADD(DAY, -30, SNF.STAY_BEGIN_DATE)
	-- 			AND CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE) <= SNF.STAY_BEGIN_DATE
	-- 		THEN 'Yes'
	-- 		ELSE 'No'
	-- 		END
	-- ,	DURING_OR_AFTER_SNF = CASE
	-- 		WHEN 	CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) > SNF.STAY_BEGIN_DATE
	-- 			AND CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) <= DATEADD(DAY, 30, SNF.STAY_END_DATE)
	-- 		THEN 'Yes'
	-- 		ELSE 'No'
	-- 		END
	-- ,	DURING_SNF_STAY = CASE
	-- 		WHEN CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) > SNF.STAY_BEGIN_DATE
	-- 			AND CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) <= SNF.STAY_END_DATE
	-- 		THEN 'Yes'
	-- 		ELSE 'No'
	-- 		END
	-- ,	WITHIN_30_DAYS = CASE
	-- 		WHEN CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) > SNF.STAY_END_DATE
	-- 		AND  CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) <= DATEADD(DAY, 30, SNF.STAY_END_DATE)
	-- 		THEN 'Yes'
	-- 		ELSE 'No'
	-- 		END
	,	DISCHARGED_TO_SNF = CASE
			WHEN CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE) >= DATEADD(DAY, -14, SNF.STAY_BEGIN_DATE)
				AND  CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE) <= SNF.STAY_BEGIN_DATE -- Widen this to within 7-14 days of the first DOS
			THEN 'Yes'
			ELSE 'No'
			END
	,	ADMIT_FROM_SNF = CASE
			WHEN CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) > SNF.STAY_BEGIN_DATE
				AND CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) <= DATEADD(DAY, 1, SNF.STAY_END_DATE) -- JSM 2022-02-23 Adjusted to take into account ED admits where the patient did not return by midnight and the facility ended billing with the previous day.
			THEN 'Yes'
			ELSE 'No'
			END
	,	ADMIT_DEPT = CLARITY_DEP_ADMIT.DEPARTMENT_NAME
	,	DISCH_DEPT = CLARITY_DEP_DISCH.DEPARTMENT_NAME
	,	PAT_ENC_HSP.DEPARTMENT_ID AS DISCH_DEPT_ID
	,	DISCH_LOCATION = CLARITY_LOC.LOC_NAME
	,	PATIENT_CLASS = ZC_PAT_CLASS.NAME
	,	PAT_ENC_HSP.ADMIT_CONF_STAT_C
	,	ZC_PAT_STATUS.NAME AS ADT_PATIENT_STATUS
	,	PATIENT_STATUS = ZC_PAT_STATUS.NAME
	,	ZC_MC_ADM_SOURCE.NAME AS ADMIT_SOURCE_NAME
	,	ZC_ADM_CATEGORY.NAME AS ADMIT_CATEGORY
	,	ZC_ED_DISPOSITION.NAME AS ED_DISPOSITION
	,	DISCH_DISPOSITION = ZC_DISCH_DISP.NAME
	,	DISCH_DESTINATION = ZC_DISCH_DEST.NAME
	,	PAT_ENC.ENC_CLOSED_YN
	,	PRIMARY_PX_NAME = ICD_PX_ONE.PROCEDURE_NAME
	,	PRIMARY_PX_BILL_CODE = ICD_PX_ONE.REF_BILL_CODE
	,	PRIMARY_DRG_NAME = CLARITY_DRG_ONE.DRG_NAME
	,	PRIMARY_DRG_BILL_CODE = DRG_ONE.DRG_MPI_CODE
	,	PRIMARY_DX_CODE = CLARITY_EDG.CURRENT_ICD10_LIST
	,	PRIMARY_DX_NAME = CLARITY_EDG.DX_NAME
	,	PRIMARY_PAYOR_NAME = PRIMARY_PAYOR_PLAN.PAYOR_NAME
	,	PRIMARY_PLAN_NAME = PRIMARY_PAYOR_PLAN.BENEFIT_PLAN_NAME
	,	SECONDARY_PAYOR_NAME = SECONDARY_PAYOR_PLAN.PAYOR_NAME
	,	SECONDARY_PLAN_NAME = SECONDARY_PAYOR_PLAN.BENEFIT_PLAN_NAME
	,	HSP_ACCOUNT.TOT_CHGS AS TOTAL_CHARGES
	,	READMIT_RISK_SCORE.READMIT_RISK_SCORE
	,	LACE_PLUS_SCORE.LACE_PLUS_SCORE
INTO #HOSP_VISITS
FROM (
	SELECT DISTINCT
		ISLANDS.PAT_ID
	,	ISLANDS.PAT_MRN_ID
	,	ISLANDS.PAT_NAME
	,	ISLANDS.SNF_STAY_ID
	,	ISLANDS.STAY_BEGIN_DATE
	,	ISLANDS.STAY_END_DATE
	FROM #ISLANDS AS ISLANDS
) AS SNF
INNER JOIN Clarity.dbo.PAT_ENC_HSP ON PAT_ENC_HSP.PAT_ID = SNF.PAT_ID
	AND CAST(PAT_ENC_HSP.HOSP_DISCH_TIME AS DATE) >= DATEADD(DAY, -14, SNF.STAY_BEGIN_DATE)
	AND CAST(PAT_ENC_HSP.HOSP_ADMSN_TIME AS DATE) <= DATEADD(DAY, 31, SNF.STAY_END_DATE) -- Changed from 30 to 31 days because facilities do not bill bed days if the patient goes to the hospital and doesn't return the same day. In those cases, the admit date will be the day after the last billed date of service. JSM 2022-04-26
INNER JOIN Clarity.dbo.PATIENT ON PATIENT.PAT_ID = PAT_ENC_HSP.PAT_ID
LEFT JOIN Clarity.dbo.PAT_ENC ON PAT_ENC_HSP.PAT_ENC_CSN_ID = PAT_ENC.PAT_ENC_CSN_ID
LEFT JOIN Clarity.dbo.CLARITY_ADT AS CLARITY_ADT_ADMIT	ON CLARITY_ADT_ADMIT.EVENT_ID = PAT_ENC_HSP.ADM_EVENT_ID
LEFT JOIN Clarity.dbo.CLARITY_DEP AS CLARITY_DEP_ADMIT ON CLARITY_DEP_ADMIT.DEPARTMENT_ID = COALESCE(CLARITY_ADT_ADMIT.DEPARTMENT_ID,PAT_ENC_HSP.DEPARTMENT_ID)
LEFT JOIN Clarity.dbo.CLARITY_ADT AS CLARITY_ADT_DISCH	ON CLARITY_ADT_DISCH.EVENT_ID = PAT_ENC_HSP.DIS_EVENT_ID
LEFT JOIN Clarity.dbo.CLARITY_DEP AS CLARITY_DEP_DISCH ON CLARITY_DEP_DISCH.DEPARTMENT_ID = COALESCE(CLARITY_ADT_DISCH.DEPARTMENT_ID,PAT_ENC_HSP.DEPARTMENT_ID)
LEFT JOIN Clarity.dbo.CLARITY_LOC ON CLARITY_DEP_DISCH.REV_LOC_ID = CLARITY_LOC.LOC_ID
LEFT JOIN Clarity.dbo.ZC_PAT_CLASS ON ZC_PAT_CLASS.ADT_PAT_CLASS_C = PAT_ENC_HSP.ADT_PAT_CLASS_C
LEFT JOIN CLARITY.dbo.ZC_PAT_STATUS ON ZC_PAT_STATUS.ADT_PATIENT_STAT_C = PAT_ENC_HSP.ADT_PATIENT_STAT_C
LEFT JOIN CLARITY.dbo.ZC_DISCH_DISP ON ZC_DISCH_DISP.DISCH_DISP_C = PAT_ENC_HSP.DISCH_DISP_C
LEFT JOIN CLARITY.dbo.ZC_DISCH_DEST ON ZC_DISCH_DEST.DISCH_DEST_C = PAT_ENC_HSP.DISCH_DEST_C
LEFT JOIN CLARITY.dbo.ZC_ADM_CATEGORY ON ZC_ADM_CATEGORY.ADMIT_CATEGORY_C = PAT_ENC_HSP.ADMIT_CATEGORY_C
LEFT JOIN Clarity.dbo.HSP_ACCOUNT ON HSP_ACCOUNT.HSP_ACCOUNT_ID = PAT_ENC_HSP.HSP_ACCOUNT_ID
LEFT JOIN Clarity.dbo.ZC_MC_ADM_SOURCE ON HSP_ACCOUNT.ADMISSION_SOURCE_C=ZC_MC_ADM_SOURCE.ADMISSION_SOURCE_C
LEFT JOIN CLARITY.dbo.ZC_ED_DISPOSITION ON ZC_ED_DISPOSITION.ED_DISPOSITION_C = PAT_ENC_HSP.ED_DISPOSITION_C
LEFT JOIN Clarity.dbo.HSP_ACCT_PX_LIST AS PX_ONE ON PX_ONE.HSP_ACCOUNT_ID = PAT_ENC_HSP.HSP_ACCOUNT_ID AND PX_ONE.LINE=1
LEFT JOIN Clarity.dbo.CL_ICD_PX AS ICD_PX_ONE ON ICD_PX_ONE.ICD_PX_ID = PX_ONE.FINAL_ICD_PX_ID
LEFT JOIN Clarity.dbo.HSP_ACCT_MULT_DRGS AS DRG_ONE ON PAT_ENC_HSP.HSP_ACCOUNT_ID = DRG_ONE.HSP_ACCOUNT_ID AND DRG_ONE.LINE=1
LEFT JOIN Clarity.dbo.CLARITY_DRG AS CLARITY_DRG_ONE ON DRG_ONE.DRG_ID = CLARITY_DRG_ONE.DRG_ID
LEFT JOIN Clarity.dbo.HSP_ACCT_DX_LIST AS HSP_ACCT_DX_LIST_PRIMARY ON HSP_ACCT_DX_LIST_PRIMARY.HSP_ACCOUNT_ID = PAT_ENC_HSP.HSP_ACCOUNT_ID
AND HSP_ACCT_DX_LIST_PRIMARY.LINE = 1
LEFT JOIN Clarity.dbo.CLARITY_EDG ON CLARITY_EDG.DX_ID = HSP_ACCT_DX_LIST_PRIMARY.DX_ID
OUTER APPLY(
	SELECT 	V_COVERAGE_PAYOR_PLAN.PAYOR_ID
		,	V_COVERAGE_PAYOR_PLAN.PAYOR_NAME
		,	V_COVERAGE_PAYOR_PLAN.BENEFIT_PLAN_ID
		,	V_COVERAGE_PAYOR_PLAN.BENEFIT_PLAN_NAME
	FROM Clarity.dbo.HSP_ACCOUNT
	LEFT JOIN Clarity.dbo.HSP_ACCT_CVG_LIST ON HSP_ACCOUNT.HSP_ACCOUNT_ID = HSP_ACCT_CVG_LIST.HSP_ACCOUNT_ID AND HSP_ACCT_CVG_LIST.LINE = 1 --Primary Coverage
	LEFT JOIN Clarity.dbo.V_COVERAGE_PAYOR_PLAN ON HSP_ACCT_CVG_LIST.COVERAGE_ID = V_COVERAGE_PAYOR_PLAN.COVERAGE_ID
	WHERE HSP_ACCOUNT.HSP_ACCOUNT_ID = PAT_ENC_HSP.HSP_ACCOUNT_ID
) PRIMARY_PAYOR_PLAN
OUTER APPLY(
	SELECT	V_COVERAGE_PAYOR_PLAN.PAYOR_ID
		,	V_COVERAGE_PAYOR_PLAN.PAYOR_NAME
		,	V_COVERAGE_PAYOR_PLAN.BENEFIT_PLAN_ID
		,	V_COVERAGE_PAYOR_PLAN.BENEFIT_PLAN_NAME
	FROM Clarity.dbo.HSP_ACCOUNT
	LEFT JOIN Clarity.dbo.HSP_ACCT_CVG_LIST ON HSP_ACCOUNT.HSP_ACCOUNT_ID = HSP_ACCT_CVG_LIST.HSP_ACCOUNT_ID AND HSP_ACCT_CVG_LIST.LINE = 2 --Secondary Coverage
	LEFT JOIN Clarity.dbo.V_COVERAGE_PAYOR_PLAN ON HSP_ACCT_CVG_LIST.COVERAGE_ID = V_COVERAGE_PAYOR_PLAN.COVERAGE_ID
	WHERE HSP_ACCOUNT.HSP_ACCOUNT_ID = PAT_ENC_HSP.HSP_ACCOUNT_ID
) AS SECONDARY_PAYOR_PLAN
OUTER APPLY( -- Get most recent predictive model score for readmission risk recorded prior to discharge
	SELECT TOP 1 TOTAL_SCORE AS READMIT_RISK_SCORE
	FROM CLARITY.dbo.V_PREDICTIVE_MODEL_SCORES
	WHERE V_PREDICTIVE_MODEL_SCORES.PAT_ENC_CSN_ID = PAT_ENC_HSP.PAT_ENC_CSN_ID
		AND ACUITY_SYSTEM_ID = 3450334502 -- JPS RISK OF UPLANNED READMISSION
	ORDER BY SCORE_FILE_LOC_DTTM DESC -- Most recent score filed prior to discharge
) AS READMIT_RISK_SCORE
OUTER APPLY( -- Get the most recent LACE+ score prior to discharge
	SELECT TOP 1 IP_FLWSHT_MEAS.MEAS_VALUE AS LACE_PLUS_SCORE
	FROM CLARITY.dbo.PAT_ENC AS LACE_PAT_ENC
	INNER JOIN CLARITY.dbo.IP_FLWSHT_REC ON IP_FLWSHT_REC.INPATIENT_DATA_ID = LACE_PAT_ENC.INPATIENT_DATA_ID
	LEFT JOIN CLARITY.dbo.IP_FLWSHT_MEAS ON IP_FLWSHT_MEAS.FSD_ID = IP_FLWSHT_REC.FSD_ID

	WHERE 	IP_FLWSHT_MEAS.FLO_MEAS_ID = '9990001048' -- LACE+ SCORE
		AND LACE_PAT_ENC.PAT_ENC_CSN_ID = PAT_ENC_HSP.PAT_ENC_CSN_ID
	ORDER BY IP_FLWSHT_MEAS.ENTRY_TIME DESC
) AS LACE_PLUS_SCORE
WHERE 1=1
	AND (
		PAT_ENC_HSP.ADT_PAT_CLASS_C IN (
			101,	-- INPATIENT
			103,	-- EMERGENCY
			104		-- OBSERVATION
		)
		OR ( -- UCC VISITS
			PAT_ENC_HSP.ADT_PAT_CLASS_C = 102 -- OUTPATIENT
			AND DISCH_DEPT_ID = 101059001	-- JPS URGENT CARE MAIN
		)
	)
	AND (PAT_ENC_HSP.ADT_PATIENT_STAT_C IS NULL OR PAT_ENC_HSP.ADT_PATIENT_STAT_C <> 6) -- 6 = HOSPITAL OUTPATIENT VISIT
;

-- SELECT
-- 		* -- 286 ROWS
-- FROM #HOSP_VISITS
-- WHERE 1=1
-- 	AND ADMIT_FROM_SNF = 'Yes'
-- 	-- AND STAY_BEGIN_DATE IS NULL
-- 	-- AND STAY_END_DATE IS NULL
-- ORDER BY PAT_NAME, HOSP_ADMSN_DATE, PAT_ENC_CSN_ID
-- -- ;


/* Step 12) Break out admits from SNF into a separate temp table in preparation for pulling inpatient readmission information */

IF OBJECT_ID(N'tempdb..#HOSP_FROM_SNF', N'U') IS NOT NULL
BEGIN DROP TABLE #HOSP_FROM_SNF PRINT 'Dropped table #HOSP_FROM_SNF' END
ELSE PRINT 'Tried to drop table #HOSP_FROM_SNF, but it did not exist.';

SELECT  SEQ = ROW_NUMBER() OVER(PARTITION BY HOSP_VISITS.SNF_STAY_ID ORDER BY HOSP_VISITS.HOSP_ADMSN_TIME ASC)
	,	HOSP_VISITS.*
INTO #HOSP_FROM_SNF
FROM #HOSP_VISITS AS HOSP_VISITS
WHERE 1=1
	AND ADMIT_FROM_SNF = 'Yes'
;

-- SELECT	*
-- FROM #HOSP_DURING_AFTER_SNF
-- WHERE 1=1
-- 	-- AND PAT_ENC_CSN_ID =
-- ORDER BY PAT_NAME, HOSP_ADMSN_DATE, PAT_ENC_CSN_ID
-- ;


/* Step 13) Get inpatient readmissions for hospital visits that occurred during SNF/LTC stays */

IF OBJECT_ID(N'tempdb..#FROM_SNF_READMITS', N'U') IS NOT NULL
BEGIN DROP TABLE #FROM_SNF_READMITS PRINT 'Dropped table #FROM_SNF_READMITS' END
ELSE PRINT 'Tried to drop table #FROM_SNF_READMITS, but it did not exist.';

WITH SEQ AS (
	SELECT	INDEX_ADMIT.PAT_ID
		,	INDEX_ADMIT.PAT_MRN_ID
		,	INDEX_ADMIT.PAT_NAME
		,	INDEX_ADMIT.SNF_STAY_ID
		,	INDEX_ADMIT.STAY_BEGIN_DATE
		,	INDEX_ADMIT.STAY_END_DATE
		,	INDEX_ADMIT.PAT_ENC_CSN_ID
		,	INDEX_ADMIT.HSP_ACCOUNT_ID
		,	INDEX_ADMIT.HOSP_ADMSN_TIME
		,	INDEX_ADMIT.INP_ADM_DATE
		,	INDEX_ADMIT.HOSP_DISCH_TIME
		,	ADMIT_SEQ = ROW_NUMBER() OVER(PARTITION BY INDEX_ADMIT.PAT_ENC_CSN_ID ORDER BY INDEX_ADMIT.STAY_BEGIN_DATE DESC) -- If a single visit is associated with more than one SNF stay, 1 = the most recent SNF stay prior to the hospital encounter
		,	READMIT_SEQ = ROW_NUMBER() OVER(PARTITION BY INDEX_ADMIT.PAT_ENC_CSN_ID ORDER BY READMIT.HOSP_ADMSN_DATE ASC)
		-- ,	INDEX_ADMIT.PRIOR_TO_SNF
		-- ,	INDEX_ADMIT.DURING_SNF_STAY
		-- ,	INDEX_ADMIT.DURING_OR_AFTER_SNF
		-- ,	INDEX_ADMIT.WITHIN_30_DAYS
		,	INDEX_ADMIT.DISCHARGED_TO_SNF
		,	INDEX_ADMIT.ADMIT_FROM_SNF
		,	INDEX_ADMIT.ADMIT_DEPT
		,	INDEX_ADMIT.DISCH_DEPT
		,	INDEX_ADMIT.DISCH_DISPOSITION
		,	INDEX_ADMIT.PATIENT_CLASS
		,	INDEX_ADMIT.PRIMARY_PX_NAME
		,	INDEX_ADMIT.PRIMARY_PX_BILL_CODE
		,	INDEX_ADMIT.PRIMARY_DRG_NAME
		,	INDEX_ADMIT.PRIMARY_DRG_BILL_CODE
		,	INDEX_ADMIT.PRIMARY_DX_CODE
		,	INDEX_ADMIT.PRIMARY_DX_NAME
		,	INDEX_ADMIT.PRIMARY_PAYOR_NAME
		,	INDEX_ADMIT.PRIMARY_PLAN_NAME
		,	INDEX_ADMIT.SECONDARY_PAYOR_NAME
		,	INDEX_ADMIT.SECONDARY_PLAN_NAME
		,	INDEX_TOTAL_CHARGES = CAST(INDEX_ADMIT.TOTAL_CHARGES AS numeric(10,2))
		,	READMIT_RISK_SCORE = CAST(INDEX_ADMIT.READMIT_RISK_SCORE AS numeric(10,0))
		,	INDEX_ADMIT.LACE_PLUS_SCORE
		,	DAYS_TO_NEXT_INP_ADM = DATEDIFF(DAY,INDEX_ADMIT.HOSP_DISCH_TIME, READMIT.HOSP_ADMSN_DATE)
		,	READMIT_PAT_ENC_CSN_ID = READMIT.PAT_ENC_CSN_ID
		,	READMIT_HSP_ACCOUNT_ID = READMIT.HSP_ACCOUNT_ID
		,	READMIT_HOSP_ADMSN_TIME = READMIT.HOSP_ADMSN_TIME
		,	READMIT_INP_ADM_DATE = READMIT.INP_ADM_DATE
		,	READMIT_HOSP_DISCH_TIME = READMIT.HOSP_DISCH_TIME
		, 	INP_ADM_7_DAY_READM_FLAG   = CASE WHEN DATEDIFF(DAY,INDEX_ADMIT.HOSP_DISCH_TIME, READMIT.HOSP_ADMSN_DATE) <= 7 THEN 1 ELSE 0 END
		, 	INP_ADM_10_DAY_READM_FLAG  = CASE WHEN DATEDIFF(DAY,INDEX_ADMIT.HOSP_DISCH_TIME, READMIT.HOSP_ADMSN_DATE) <= 10 THEN 1 ELSE 0 END
		, 	INP_ADM_14_DAY_READM_FLAG  = CASE WHEN DATEDIFF(DAY,INDEX_ADMIT.HOSP_DISCH_TIME, READMIT.HOSP_ADMSN_DATE) <= 14 THEN 1 ELSE 0 END
		, 	INP_ADM_30_DAY_READM_FLAG  = CASE WHEN DATEDIFF(DAY,INDEX_ADMIT.HOSP_DISCH_TIME, READMIT.HOSP_ADMSN_DATE) <= 30 THEN 1 ELSE 0 END
		,	READMIT_ADMIT_DEPT = READMIT.ADMIT_DEPT
		,	READMIT_DISCH_DEPT_ID = READMIT.DISCH_DEPT_ID
		,	READMIT_DISCH_DEPT = READMIT.DISCH_DEPT
		,	READMIT_DISCH_LOCATION = READMIT.DISCH_LOCATION
		,	READMIT_PATIENT_CLASS = READMIT.PATIENT_CLASS
		,	READMIT_ADT_PATIENT_STATUS = READMIT.ADT_PATIENT_STATUS
		,	READMIT_DISCH_DISPOSITION = READMIT.DISCH_DISPOSITION
		,	READMIT_PRIMARY_PX_NAME = READMIT.PRIMARY_PX_NAME
		,	READMIT_PRIMARY_PX_BILL_CODE = READMIT.PRIMARY_PX_BILL_CODE
		,	READMIT_PRIMARY_DRG_NAME = READMIT.PRIMARY_DRG_NAME
		,	READMIT_PRIMARY_DRG_BILL_CODE = READMIT.PRIMARY_DRG_BILL_CODE
		,	READMIT_PRIMARY_DX_CODE = READMIT.PRIMARY_DX_CODE
		,	READMIT_PRIMARY_DX_NAME = READMIT.PRIMARY_DX_NAME
		,	READMIT_PRIMARY_PAYOR_NAME = READMIT.PRIMARY_PAYOR_NAME
		,	READMIT_PRIMARY_PLAN_NAME = READMIT.PRIMARY_PLAN_NAME
		,	READMIT_SECONDARY_PAYOR_NAME = READMIT.SECONDARY_PAYOR_NAME
		,	READMIT_SECONDARY_PLAN_NAME = READMIT.SECONDARY_PLAN_NAME
		,	READMIT_TOTAL_CHARGES = CAST(READMIT.TOTAL_CHARGES AS numeric(10,2))
	FROM #HOSP_FROM_SNF AS INDEX_ADMIT
	LEFT JOIN #HOSP_FROM_SNF AS READMIT ON READMIT.PAT_ID = INDEX_ADMIT.PAT_ID
		AND READMIT.INP_ADM_DATE IS NOT NULL -- Only inpatient readmits
		AND READMIT.HOSP_ADMSN_TIME > INDEX_ADMIT.HOSP_DISCH_TIME
		AND READMIT.HOSP_ADMSN_DATE <= DATEADD(DAY, 30, INDEX_ADMIT.HOSP_DISCH_DATE)
		AND READMIT.ADMIT_CONF_STAT_C NOT IN (2, 3) /*006 BA*/ --(Admit Conf Status not Canceled - 3 and not Pending - 2)
		AND INDEX_ADMIT.DISCH_DISPOSITION NOT IN (
			SELECT	CODE_NAME
			FROM dbo.STANDARD_DEFINITIONS
			WHERE 1=1
				AND CODE_GROUP = 'Excluded index discharge dispositions'
		)
	WHERE 1=1
		AND INDEX_ADMIT.PATIENT_CLASS = 'Inpatient'
)
SELECT *
INTO #FROM_SNF_READMITS
FROM SEQ
WHERE 1=1
	AND ADMIT_SEQ = 1 -- Most recent SNF stay prior to the index discharge if one visit is associated with more than one SNF stay
	AND READMIT_SEQ = 1 -- First admission subsequent to index discharge
ORDER BY PAT_NAME, PAT_ENC_CSN_ID
;

-- SELECT	*
-- 	-- PAT_ENC_CSN_ID, COUNT (*) AS CNT
-- FROM #FROM_SNF_READMITS AS READMITS
-- WHERE 1=1
-- 	AND SNF_STAY_ID IS NOT NULL
-- ORDER BY PAT_NAME, SNF_STAY_ID, HOSP_ADMSN_TIME, PAT_ENC_CSN_ID
-- ;


/* Step 14) Combine hospital visits tables */

-- Set report start and end dates

DECLARE @RPT_START_DATE DATE = (SELECT MIN(DOS_FROM) FROM #SNF)
DECLARE @RPT_END_DATE DATE = (SELECT MAX(DOS_TO) FROM #SNF)

IF OBJECT_ID(N'tempdb..#DATEVARS', N'U') IS NOT NULL
BEGIN DROP TABLE #DATEVARS PRINT 'Dropped table #DATEVARS' END
ELSE PRINT 'Tried to drop table #DATEVARS, but it did not exist.';

SELECT 	@RPT_START_DATE AS RPT_START_DATE
	,	@RPT_END_DATE AS RPT_END_DATE
INTO #DATEVARS
;


IF OBJECT_ID(N'tempdb..#HOSP_COMBINED', N'U') IS NOT NULL
BEGIN DROP TABLE #HOSP_COMBINED PRINT 'Dropped table #HOSP_COMBINED' END
ELSE PRINT 'Tried to drop table #HOSP_COMBINED, but it did not exist.';

SELECT 	RPT_START_DATE
	,	RPT_END_DATE
	,	GETDATE() as RPT_RUN_DATE
	,	VISITS.PAT_ID
	,	VISITS.PAT_MRN_ID
	,	VISITS.PAT_NAME
	,	VISITS.SNF_STAY_ID
	,	VISITS.STAY_BEGIN_DATE
	,	VISITS.STAY_END_DATE
	,	VISITS.PAT_ENC_CSN_ID
	,	VISITS.HSP_ACCOUNT_ID
	,	VISITS.HOSP_ADMSN_TIME
	,	VISITS.INP_ADM_DATE
	,	VISITS.HOSP_DISCH_TIME
	-- ,	VISITS.PRIOR_TO_SNF
	-- ,	VISITS.DURING_SNF_STAY
	-- ,	VISITS.DURING_OR_AFTER_SNF
	-- ,	VISITS.WITHIN_30_DAYS
	,	VISITS.DISCHARGED_TO_SNF
	,	VISITS.ADMIT_FROM_SNF
	,	VISITS.ADMIT_DEPT
	,	VISITS.DISCH_DEPT
	,	VISITS.DISCH_DEPT_ID
	,	VISITS.DISCH_DISPOSITION
	,	VISITS.PATIENT_CLASS
	,	VISITS.PRIMARY_PX_NAME
	,	VISITS.PRIMARY_PX_BILL_CODE
	,	VISITS.PRIMARY_DRG_NAME
	,	VISITS.PRIMARY_DRG_BILL_CODE
	,	VISITS.PRIMARY_DX_CODE
	,	VISITS.PRIMARY_DX_NAME
	,	VISITS.PRIMARY_PAYOR_NAME
	,	VISITS.PRIMARY_PLAN_NAME
	,	VISITS.SECONDARY_PAYOR_NAME
	,	VISITS.SECONDARY_PLAN_NAME
	,	INDEX_TOTAL_CHARGES
	,	VISITS.READMIT_RISK_SCORE
	,	VISITS.LACE_PLUS_SCORE
	,	DAYS_TO_NEXT_INP_ADM
	,	READMIT_PAT_ENC_CSN_ID
	,	READMIT_HSP_ACCOUNT_ID
	,	READMIT_HOSP_ADMSN_TIME
	,	READMIT_INP_ADM_DATE
	,	READMIT_HOSP_DISCH_TIME
	, 	INP_ADM_7_DAY_READM_FLAG = COALESCE(INP_ADM_7_DAY_READM_FLAG, 0)
	, 	INP_ADM_10_DAY_READM_FLAG = COALESCE(INP_ADM_10_DAY_READM_FLAG, 0)
	, 	INP_ADM_14_DAY_READM_FLAG = COALESCE(INP_ADM_14_DAY_READM_FLAG, 0)
	, 	INP_ADM_30_DAY_READM_FLAG = COALESCE(INP_ADM_30_DAY_READM_FLAG, 0)
	,	READMIT_ADMIT_DEPT
	,	READMIT_DISCH_DEPT
	,	READMIT_DISCH_DEPT_ID
	,	READMIT_DISCH_LOCATION
	,	READMIT_PATIENT_CLASS
	,	READMIT_ADT_PATIENT_STATUS
	,	READMIT_DISCH_DISPOSITION
	,	READMIT_PRIMARY_PX_NAME
	,	READMIT_PRIMARY_PX_BILL_CODE
	,	READMIT_PRIMARY_DRG_NAME
	,	READMIT_PRIMARY_DRG_BILL_CODE
	,	READMIT_PRIMARY_DX_CODE
	,	READMIT_PRIMARY_DX_NAME
	,	READMIT_PRIMARY_PAYOR_NAME
	,	READMIT_PRIMARY_PLAN_NAME
	,	READMIT_SECONDARY_PAYOR_NAME
	,	READMIT_SECONDARY_PLAN_NAME
	,	READMIT_TOTAL_CHARGES
INTO #HOSP_COMBINED
FROM #HOSP_VISITS AS VISITS
INNER JOIN #DATEVARS ON 1=1
LEFT JOIN #FROM_SNF_READMITS AS FROM_SNF ON FROM_SNF.PAT_ENC_CSN_ID = VISITS.PAT_ENC_CSN_ID
	AND FROM_SNF.SNF_STAY_ID = VISITS.SNF_STAY_ID

-- SELECT	*
-- FROM #HOSP_COMBINED
-- WHERE 1=1
-- 	AND ADMIT_FROM_SNF = 'Yes'
-- ORDER BY PAT_NAME, SNF_STAY_ID, PAT_ENC_CSN_ID, READMIT_PAT_ENC_CSN_ID


/* Step 15) Combine temp tables from prior steps to create a detail table for SNF/LTC utilization */

IF OBJECT_ID(N'tempdb..#COMBINED', N'U') IS NOT NULL
BEGIN DROP TABLE #COMBINED PRINT 'Dropped table #COMBINED' END
ELSE PRINT 'Tried to drop table #COMBINED, but it did not exist.';

SELECT	RPT_START_DATE
	,	RPT_END_DATE
	,	GETDATE() as RPT_RUN_DATE
	,	SNF.IPA
	,	SNF.TIN
	,	SNF.PARENT_FACILITY
	,	SNF.PROVIDER_ID
	,	SNF.PROVIDER_NAME
	,	ISLANDS.SNF_STAY_ID
	,	SNF.MEMBER_NUMBER
	,	SNF.PAT_ID
	,	PAT_MRN_ID = COALESCE(SNF.PAT_MRN_ID, SNF.MEMBER_NUMBER)
	,	SNF.PAT_NAME
	,	SNF.MEMBER_LAST_NAME
	,	SNF.MEMBER_FIRST_NAME
	,	SNF.BENEFIT_PLAN
	,	SNF.CLAIM_NUMBER
	,	SNF.WORKSHEET_NUMBER
	,	SNF.LINE_NUMBER
	,	SNF.CLAIM_LINE_SEQ
	,	SNF.DOS_FROM
	,	SNF.DOS_TO
	,	ISLANDS.STAY_BEGIN_DATE
	,	ISLANDS.STAY_END_DATE
	,	SNF.LOS
	,	ISLANDS.LENGTH_OF_STAY
	,	ISLANDS.TOTAL_DOS
	,	SNF.PROC_CODE
	,	SNF.PROC_DESCRIPTION
	,	SNF.UNITS
	,	SNF.UNIT_RATE
	,	SNF.TOTAL_CHARGES
	,	SNF.PAID_AMOUNT
	,	SNF.REMARK
	,	CLAIM_LINE_IN_STAY = ROW_NUMBER() OVER(PARTITION BY ISLANDS.SNF_STAY_ID ORDER BY SNF.DOS_FROM, SNF.DOS_TO, SNF.CLAIM_NUMBER, SNF.WORKSHEET_NUMBER, SNF.LINE_NUMBER)
	,	PAID_CLAIM_LINE_SEQ.PAID_CLAIM_LINE_SEQ
	,	ISLANDS.STAY_HAS_PAID_CLAIMS_YN 
	,	PCP_PROV_ID = COALESCE(DEMO.PCP_PROV_ID, -1)
	,	PCP_PROV_NAME = COALESCE(DEMO.PCP_PROV_NAME, 'No assigned PCP')
	,	PCP_MED_HOME = COALESCE(DEMO.PCP_MED_HOME, 'No PCP medical home')
	,	PAT_MED_HOME = COALESCE(DEMO.PAT_MED_HOME, 'No assigned medical home')
	,	EMPANELED_PCP_YN = COALESCE(DEMO.EMPANELED_PCP_YN, 'No')
	,	HOSPITAL_TO_SNF = COALESCE(HOSP_BEFORE_SNF.DISCHARGED_TO_SNF, 'No')
	,	LAST_HOSP_ENC_TYPE = CASE
			WHEN HOSP_BEFORE_SNF.PATIENT_CLASS = 'Outpatient' THEN 'Urgent Care'
			WHEN HOSP_BEFORE_SNF.PATIENT_CLASS IS NULL THEN 'N/A'
			ELSE HOSP_BEFORE_SNF.PATIENT_CLASS
			END
	,	HOSP_BEFORE_SNF.PAT_ENC_CSN_ID AS LAST_HOSP_CSN_ID
	,	HOSP_BEFORE_SNF.HOSP_ADMSN_TIME AS LAST_HOSP_ADMSN_TIME
	,	HOSP_BEFORE_SNF.HOSP_DISCH_TIME AS LAST_HOSP_DISCH_TIME
	,	HOSP_BEFORE_SNF.DISCH_DEPT AS LAST_HOSP_DISCH_DEPT
	,	HOSP_BEFORE_SNF.PRIMARY_DX_CODE as DISCH_DX_CODE
	,	HOSP_BEFORE_SNF.PRIMARY_DX_NAME as DISCH_DX_NAME
	,	HOSP_BEFORE_SNF.DISCH_DISPOSITION
INTO #COMBINED
FROM #ISLANDS as ISLANDS
INNER JOIN #DATEVARS on 1=1
LEFT JOIN #SNF as SNF ON SNF.CHARGE_ID = ISLANDS.CHARGE_ID
LEFT JOIN #DEMO AS DEMO ON DEMO.PAT_ID = SNF.PAT_ID
OUTER APPLY (
	SELECT TOP 1
			DISCHARGED_TO_SNF
		,	PAT_ENC_CSN_ID
		,	HOSP_ADMSN_TIME
		,	HOSP_DISCH_TIME
		,	DISCH_DEPT_ID
		,	DISCH_DEPT
		,	PRIMARY_DX_CODE
		,	PRIMARY_DX_NAME
		,	PATIENT_CLASS
		,	DISCH_DISPOSITION
	FROM #HOSP_VISITS
	WHERE 1=1
		AND #HOSP_VISITS.SNF_STAY_ID = ISLANDS.SNF_STAY_ID
		-- AND PRIOR_TO_SNF = 'Yes' -- JSM 2022-01-26 Changed to DISCHARGED_TO_SNF to restrict the discharges to those that occurred within 14 days instead of within 30 days of post-acute care facility admission
		AND DISCHARGED_TO_SNF = 'Yes'
	ORDER BY HOSP_DISCH_TIME DESC
) AS HOSP_BEFORE_SNF
LEFT JOIN (	-- PAID_CLAIM_LINE_SEQ will be used to filter the final detail data to one row per stay for visualization in the Power BI report. This was necessary because the stay type was showing incorrectly in the Power BI report if the facility initially billed a patient’s stay as one stay type and later sent a corrected claim with a different stay type.
	SELECT	DISTINCT 
			ISLANDS.SNF_STAY_ID
		,	ISLANDS.CHARGE_ID
		,	PAID_CLAIM_LINE_SEQ = CASE	-- 
			WHEN ISLANDS.PAID_AMOUNT > 0 
			THEN ROW_NUMBER() OVER(PARTITION BY ISLANDS.SNF_STAY_ID ORDER BY SNF.DOS_FROM, SNF.DOS_TO, SNF.CLAIM_NUMBER, SNF.WORKSHEET_NUMBER, SNF.LINE_NUMBER)
			ELSE NULL
			END
		FROM #ISLANDS AS ISLANDS
		INNER JOIN #SNF as SNF ON SNF.CHARGE_ID = ISLANDS.CHARGE_ID
		WHERE 1=1
			AND ISLANDS.PAID_AMOUNT > 0	-- Only calculate PAID_CLAIM_LINE_SEQ on paid claim lines so that there will always be a row with a value of 1. Without this, some stays did not have a line where PAID_CLAIM_LINE_SEQ = 1 because the first paid claim line was not the first claim line in the order specified in the ORDER BY clause of the ROW_NUMBER function.	JSM 2022-07-27
) AS PAID_CLAIM_LINE_SEQ ON PAID_CLAIM_LINE_SEQ.CHARGE_ID = ISLANDS.CHARGE_ID
;

-- SELECT
-- 		*
-- FROM #COMBINED AS COMBINED
-- -- FROM pbi.vw_POST_ACUTE_CARE_DASHBOARD_SNF_STAYS
-- WHERE 1=1
-- 	-- AND CLAIM_NUMBER = ''
-- ORDER BY PAT_NAME, PAT_MRN_ID, CLAIM_NUMBER, CLAIM_LINE_SEQ
-- ;


/* Step 16) Create or truncate landing tables and insert data */

/* Step 16A ) SNF/LTC claims */

-- -- DROP TABLE pbi.POST_ACUTE_CARE_DASHBOARD_DATA
IF OBJECT_ID('pbi.POST_ACUTE_CARE_DASHBOARD_DATA', 'U') IS NULL
BEGIN
	CREATE TABLE pbi.POST_ACUTE_CARE_DASHBOARD_DATA(
		[RPT_START_DATE] [datetime] NULL,
		[RPT_END_DATE] [datetime] NULL,
		[RPT_RUN_DATE] [datetime] NULL,
		[IPA] [varchar](255) NULL,
		[TIN] [varchar](255) NULL,
		[PARENT_FACILITY] [varchar](255) NULL,
		[PROVIDER_ID] [varchar](255) NULL,
		[PROVIDER_NAME] [varchar](255) NULL,
		[SNF_STAY_ID] [int] NULL,
		[MBR_NUMBER] [varchar](255) NULL,
		[PAT_ID] [varchar](255) NULL,
		[PAT_MRN_ID] [varchar](255) NULL,
		[PAT_NAME] [varchar](255) NULL,
		[MEMBER_LAST_NAME] [varchar](255) NULL,
		[MEMBER_FIRST_NAME] [varchar](255) NULL,
		[INS_PLAN] [varchar](255) NULL,
		[CLAIM_NUMBER] [numeric](18, 0) NULL,
		[WORKSHEET_NUMBER] [numeric](18, 0) NULL,
		[LINE_NUMBER] [numeric](18, 0) NULL,
		[DOS_FROM] [date] NULL,
		[DOS_TO] [date] NULL,
		[MIN_DOS_FROM] [date] NULL,
		[MAX_DOS_TO] [date] NULL,
		[LOS] [numeric](18, 0) NULL,
		[LENGTH_OF_STAY] [numeric](18, 0) NULL,
		[TOTAL_DOS] [numeric](18, 0) NULL,
		[PROC_CODE] [varchar](255) NULL,
		[PROC_DESCRIPTION] [varchar](255) NULL,
		[UNITS] [numeric](18, 2) NULL,
		[UNIT_RATE] [numeric](18, 2) NULL,
		[TOTAL_CHARGES] [numeric](18, 2) NULL,
		[PAID_AMOUNT] [numeric](18, 2) NULL,
		[REMARK] [varchar](255) NULL,
		[CLAIM_LINE_IN_STAY] [int] NULL,
		[PAID_CLAIM_LINE_SEQ] [int] NULL,
		[STAY_HAS_PAID_CLAIMS_YN] [varchar](3) NULL,
		[PCP_PROV_ID] [int] NULL,
		[PCP_PROV_NAME] [varchar](255) NULL,
		[PCP_MED_HOME] [varchar](255) NULL,
		[PAT_MED_HOME] [varchar](255) NULL,
		[EMPANELED_PCP_YN] [varchar](3) NULL,
		[HOSPITAL_TO_SNF] [varchar](3) NULL,
		[LAST_HOSP_ENC_TYPE] [varchar](50) NULL,
		[LAST_HOSP_CSN_ID] [numeric](18, 0) NULL,
		[LAST_HOSP_ADMSN_TIME] [datetime] NULL,
		[LAST_HOSP_DISCH_TIME] [datetime] NULL,
		[LAST_HOSP_DISCH_DEPT] [varchar](255) NULL,
		[DISCH_DX_CODE] [varchar](255) NULL,
		[DISCH_DX_NAME] [varchar](255) NULL,
		[DISCH_DISPOSITION] [varchar](255) NULL
	)
	PRINT 'Created table pbi.POST_ACUTE_CARE_DASHBOARD_DATA'
END
ELSE
BEGIN
	TRUNCATE TABLE pbi.POST_ACUTE_CARE_DASHBOARD_DATA
	PRINT 'Truncated table pbi.POST_ACUTE_CARE_DASHBOARD_DATA'
END
;


/* Insert combined detail data into landing table */

INSERT INTO pbi.POST_ACUTE_CARE_DASHBOARD_DATA (
		RPT_START_DATE
	,	RPT_END_DATE
	,	RPT_RUN_DATE
	,	IPA
	,	TIN
	,	PARENT_FACILITY
	,	PROVIDER_ID
	,	PROVIDER_NAME
	,	SNF_STAY_ID
	,	MBR_NUMBER
	,	PAT_ID
	,	PAT_MRN_ID
	,	PAT_NAME
	,	MEMBER_LAST_NAME
	,	MEMBER_FIRST_NAME
	,	INS_PLAN
	,	CLAIM_NUMBER
	,	WORKSHEET_NUMBER
	,	LINE_NUMBER
	,	DOS_FROM
	,	DOS_TO
	,	MIN_DOS_FROM
	,	MAX_DOS_TO
	,	LOS
	,	LENGTH_OF_STAY
	,	TOTAL_DOS
	,	PROC_CODE
	,	PROC_DESCRIPTION
	,	TOTAL_CHARGES
	,	PAID_AMOUNT
	,	UNITS
	,	UNIT_RATE
	,	REMARK
	,	CLAIM_LINE_IN_STAY
	,	PAID_CLAIM_LINE_SEQ
	,	STAY_HAS_PAID_CLAIMS_YN
	,	PCP_PROV_ID
	,	PCP_PROV_NAME
	,	PCP_MED_HOME
	,	PAT_MED_HOME
	,	EMPANELED_PCP_YN
	,	HOSPITAL_TO_SNF
	,	LAST_HOSP_ENC_TYPE
	,	LAST_HOSP_CSN_ID
	,	LAST_HOSP_ADMSN_TIME
	,	LAST_HOSP_DISCH_TIME
	,	LAST_HOSP_DISCH_DEPT
	,	DISCH_DX_CODE
	,	DISCH_DX_NAME
	,	DISCH_DISPOSITION
)
SELECT 	RPT_START_DATE
	,	RPT_END_DATE
	,	RPT_RUN_DATE
	,	IPA
	,	TIN
	,	PARENT_FACILITY
	,	PROVIDER_ID
	,	PROVIDER_NAME
	,	SNF_STAY_ID
	,	MEMBER_NUMBER
	,	PAT_ID
	,	PAT_MRN_ID
	,	PAT_NAME
	,	MEMBER_LAST_NAME
	,	MEMBER_FIRST_NAME
	,	BENEFIT_PLAN
	,	CLAIM_NUMBER
	,	WORKSHEET_NUMBER
	,	LINE_NUMBER
	,	DOS_FROM
	,	DOS_TO
	,	MIN_DOS_FROM = STAY_BEGIN_DATE
	,	MAX_DOS_TO = STAY_END_DATE
	,	LOS
	,	LENGTH_OF_STAY
	,	TOTAL_DOS
	,	PROC_CODE
	,	PROC_DESCRIPTION
	,	TOTAL_CHARGES
	,	PAID_AMOUNT
	,	UNITS
	,	UNIT_RATE
	,	REMARK
	,	CLAIM_LINE_IN_STAY
	,	PAID_CLAIM_LINE_SEQ
	,	STAY_HAS_PAID_CLAIMS_YN
	,	PCP_PROV_ID
	,	PCP_PROV_NAME
	,	PCP_MED_HOME
	,	PAT_MED_HOME
	,	EMPANELED_PCP_YN
	,	HOSPITAL_TO_SNF
	,	LAST_HOSP_ENC_TYPE
	,	LAST_HOSP_CSN_ID
	,	LAST_HOSP_ADMSN_TIME
	,	LAST_HOSP_DISCH_TIME
	,	LAST_HOSP_DISCH_DEPT
	,	DISCH_DX_CODE
	,	DISCH_DX_NAME
	,	DISCH_DISPOSITION
FROM #COMBINED
;

-- SELECT *
-- FROM #COMBINED
-- WHERE 1=1
-- 	AND PROVIDER_NAME IS NULL


/* Step 16B ) Hospital admits during stays */

-- -- DROP TABLE pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS
IF OBJECT_ID('pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS', 'U') IS NULL
BEGIN
	CREATE TABLE pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS(
		[RPT_START_DATE] [datetime] NULL,
		[RPT_END_DATE] [datetime] NULL,
		[RPT_RUN_DATE] [datetime] NULL,
		[PAT_ID] [varchar](30) NULL,
		[PAT_MRN_ID] [varchar](30) NULL,
		[PAT_NAME] [varchar](255) NULL,
		[SNF_STAY_ID] [int] NULL,
		[MIN_DOS_FROM] [date] NULL,
		[MAX_DOS_TO] [date] NULL,
		[PAT_ENC_CSN_ID] [numeric](18, 0) NOT NULL,
		[HSP_ACCOUNT_ID] [numeric](18, 0) NULL,
		[HOSP_ADMSN_TIME] [datetime] NULL,
		[INP_ADM_DATE] [datetime] NULL,
		[HOSP_DISCH_TIME] [datetime] NULL,
		-- [PRIOR_TO_SNF] [varchar](3) NOT NULL,
		-- [DURING_SNF_STAY] [varchar](3) NOT NULL,
		-- [DURING_OR_AFTER_SNF] [varchar](3) NOT NULL,
		-- [WITHIN_30_DAYS] [varchar](3) NOT NULL,
		[DISCHARGED_TO_SNF] [varchar](3) NOT NULL,
		[ADMIT_FROM_SNF] [varchar](3) NOT NULL,
		[ADMIT_DEPT] [varchar](254) NULL,
		[DISCH_DEPT] [varchar](254) NULL,
		[DISCH_DEPT_ID] [numeric](18, 0) NULL,
		[DISCH_DISPOSITION] [varchar](254) NULL,
		[PATIENT_CLASS] [varchar](254) NULL,
		[PRIMARY_PX_NAME] [varchar](254) NULL,
		[PRIMARY_PX_BILL_CODE] [varchar](254) NULL,
		[PRIMARY_DRG_NAME] [varchar](223) NULL,
		[PRIMARY_DRG_BILL_CODE] [varchar](254) NULL,
		[PRIMARY_DX_CODE] [varchar](254) NULL,
		[PRIMARY_DX_NAME] [varchar](200) NULL,
		[PRIMARY_PAYOR_NAME] [varchar](80) NULL,
		[PRIMARY_PLAN_NAME] [varchar](100) NULL,
		[SECONDARY_PAYOR_NAME] [varchar](80) NULL,
		[SECONDARY_PLAN_NAME] [varchar](100) NULL,
		[INDEX_TOTAL_CHARGES] [numeric](18, 5) NULL,
		[READMIT_RISK_SCORE] [numeric](18, 5) NULL,
		[LACE_PLUS_SCORE] [varchar](2500) NULL,
		[DAYS_TO_NEXT_INP_ADM] [int] NULL,
		[READMIT_PAT_ENC_CSN_ID] [numeric](18, 0) NULL,
		[READMIT_HSP_ACCOUNT_ID] [numeric](18, 0) NULL,
		[READMIT_HOSP_ADMSN_TIME] [datetime] NULL,
		[READMIT_INP_ADM_DATE] [datetime] NULL,
		[READMIT_HOSP_DISCH_TIME] [datetime] NULL,
		[INP_ADM_7_DAY_READM_FLAG] [int] NOT NULL,
		[INP_ADM_10_DAY_READM_FLAG] [int] NOT NULL,
		[INP_ADM_14_DAY_READM_FLAG] [int] NOT NULL,
		[INP_ADM_30_DAY_READM_FLAG] [int] NOT NULL,
		[READMIT_ADMIT_DEPT] [varchar](254) NULL,
		[READMIT_DISCH_DEPT] [varchar](254) NULL,
		[READMIT_DISCH_DEPT_ID] [numeric](18, 0) NULL,
		[READMIT_DISCH_LOCATION] [varchar](80) NULL,
		[READMIT_PATIENT_CLASS] [varchar](254) NULL,
		[READMIT_ADT_PATIENT_STATUS] [varchar](254) NULL,
		[READMIT_DISCH_DISPOSITION] [varchar](254) NULL,
		[READMIT_PRIMARY_PX_NAME] [varchar](254) NULL,
		[READMIT_PRIMARY_PX_BILL_CODE] [varchar](254) NULL,
		[READMIT_PRIMARY_DRG_NAME] [varchar](223) NULL,
		[READMIT_PRIMARY_DRG_BILL_CODE] [varchar](254) NULL,
		[READMIT_PRIMARY_DX_CODE] [varchar](254) NULL,
		[READMIT_PRIMARY_DX_NAME] [varchar](200) NULL,
		[READMIT_PRIMARY_PAYOR_NAME] [varchar](80) NULL,
		[READMIT_PRIMARY_PLAN_NAME] [varchar](100) NULL,
		[READMIT_SECONDARY_PAYOR_NAME] [varchar](80) NULL,
		[READMIT_SECONDARY_PLAN_NAME] [varchar](100) NULL,
		[READMIT_TOTAL_CHARGES] [numeric](18, 0) NULL
	)
	PRINT 'Created table pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS'
END
ELSE
BEGIN
	TRUNCATE TABLE pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS
	PRINT 'Truncated table pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS'
END
;


/* Insert combined detail data into landing table */

INSERT INTO pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS (
		RPT_START_DATE
	,	RPT_END_DATE
	,	RPT_RUN_DATE
	,	PAT_ID
	,	PAT_MRN_ID
	,	PAT_NAME
	,	SNF_STAY_ID
	,	MIN_DOS_FROM
	,	MAX_DOS_TO
	,	PAT_ENC_CSN_ID
	,	HSP_ACCOUNT_ID
	,	HOSP_ADMSN_TIME
	,	INP_ADM_DATE
	,	HOSP_DISCH_TIME
	-- ,	PRIOR_TO_SNF
	-- ,	DURING_SNF_STAY
	-- ,	DURING_OR_AFTER_SNF
	-- ,	WITHIN_30_DAYS
	,	DISCHARGED_TO_SNF
	,	ADMIT_FROM_SNF
	,	ADMIT_DEPT
	,	DISCH_DEPT
	,	DISCH_DEPT_ID
	,	DISCH_DISPOSITION
	,	PATIENT_CLASS
	,	PRIMARY_PX_NAME
	,	PRIMARY_PX_BILL_CODE
	,	PRIMARY_DRG_NAME
	,	PRIMARY_DRG_BILL_CODE
	,	PRIMARY_DX_CODE
	,	PRIMARY_DX_NAME
	,	PRIMARY_PAYOR_NAME
	,	PRIMARY_PLAN_NAME
	,	SECONDARY_PAYOR_NAME
	,	SECONDARY_PLAN_NAME
	,	INDEX_TOTAL_CHARGES
	,	READMIT_RISK_SCORE
	,	LACE_PLUS_SCORE
	,	DAYS_TO_NEXT_INP_ADM
	,	READMIT_PAT_ENC_CSN_ID
	,	READMIT_HSP_ACCOUNT_ID
	,	READMIT_HOSP_ADMSN_TIME
	,	READMIT_INP_ADM_DATE
	,	READMIT_HOSP_DISCH_TIME
	,	INP_ADM_7_DAY_READM_FLAG
	,	INP_ADM_10_DAY_READM_FLAG
	,	INP_ADM_14_DAY_READM_FLAG
	,	INP_ADM_30_DAY_READM_FLAG
	,	READMIT_ADMIT_DEPT
	,	READMIT_DISCH_DEPT
	,	READMIT_DISCH_DEPT_ID
	,	READMIT_DISCH_LOCATION
	,	READMIT_PATIENT_CLASS
	,	READMIT_ADT_PATIENT_STATUS
	,	READMIT_DISCH_DISPOSITION
	,	READMIT_PRIMARY_PX_NAME
	,	READMIT_PRIMARY_PX_BILL_CODE
	,	READMIT_PRIMARY_DRG_NAME
	,	READMIT_PRIMARY_DRG_BILL_CODE
	,	READMIT_PRIMARY_DX_CODE
	,	READMIT_PRIMARY_DX_NAME
	,	READMIT_PRIMARY_PAYOR_NAME
	,	READMIT_PRIMARY_PLAN_NAME
	,	READMIT_SECONDARY_PAYOR_NAME
	,	READMIT_SECONDARY_PLAN_NAME
	,	READMIT_TOTAL_CHARGES
)
SELECT	RPT_START_DATE
	,	RPT_END_DATE
	,	RPT_RUN_DATE
	,	PAT_ID
	,	PAT_MRN_ID
	,	PAT_NAME
	,	SNF_STAY_ID
	,	MIN_DOS_FROM = STAY_BEGIN_DATE
	,	MAX_DOS_TO = STAY_END_DATE
	,	PAT_ENC_CSN_ID
	,	HSP_ACCOUNT_ID
	,	HOSP_ADMSN_TIME
	,	INP_ADM_DATE
	,	HOSP_DISCH_TIME
	-- ,	PRIOR_TO_SNF
	-- ,	DURING_SNF_STAY
	-- ,	DURING_OR_AFTER_SNF
	-- ,	WITHIN_30_DAYS
	,	DISCHARGED_TO_SNF
	,	ADMIT_FROM_SNF
	,	ADMIT_DEPT
	,	DISCH_DEPT
	,	DISCH_DEPT_ID
	,	DISCH_DISPOSITION
	,	PATIENT_CLASS
	,	PRIMARY_PX_NAME
	,	PRIMARY_PX_BILL_CODE
	,	PRIMARY_DRG_NAME
	,	PRIMARY_DRG_BILL_CODE
	,	PRIMARY_DX_CODE
	,	PRIMARY_DX_NAME
	,	PRIMARY_PAYOR_NAME
	,	PRIMARY_PLAN_NAME
	,	SECONDARY_PAYOR_NAME
	,	SECONDARY_PLAN_NAME
	,	INDEX_TOTAL_CHARGES
	,	READMIT_RISK_SCORE
	,	LACE_PLUS_SCORE
	,	DAYS_TO_NEXT_INP_ADM
	,	READMIT_PAT_ENC_CSN_ID
	,	READMIT_HSP_ACCOUNT_ID
	,	READMIT_HOSP_ADMSN_TIME
	,	READMIT_INP_ADM_DATE
	,	READMIT_HOSP_DISCH_TIME
	, 	INP_ADM_7_DAY_READM_FLAG = COALESCE(INP_ADM_7_DAY_READM_FLAG, 0)
	, 	INP_ADM_10_DAY_READM_FLAG = COALESCE(INP_ADM_10_DAY_READM_FLAG, 0)
	, 	INP_ADM_14_DAY_READM_FLAG = COALESCE(INP_ADM_14_DAY_READM_FLAG, 0)
	, 	INP_ADM_30_DAY_READM_FLAG = COALESCE(INP_ADM_30_DAY_READM_FLAG, 0)
	,	READMIT_ADMIT_DEPT
	,	READMIT_DISCH_DEPT
	,	READMIT_DISCH_DEPT_ID
	,	READMIT_DISCH_LOCATION
	,	READMIT_PATIENT_CLASS
	,	READMIT_ADT_PATIENT_STATUS
	,	READMIT_DISCH_DISPOSITION
	,	READMIT_PRIMARY_PX_NAME
	,	READMIT_PRIMARY_PX_BILL_CODE
	,	READMIT_PRIMARY_DRG_NAME
	,	READMIT_PRIMARY_DRG_BILL_CODE
	,	READMIT_PRIMARY_DX_CODE
	,	READMIT_PRIMARY_DX_NAME
	,	READMIT_PRIMARY_PAYOR_NAME
	,	READMIT_PRIMARY_PLAN_NAME
	,	READMIT_SECONDARY_PAYOR_NAME
	,	READMIT_SECONDARY_PLAN_NAME
	,	READMIT_TOTAL_CHARGES
FROM #HOSP_COMBINED
WHERE 1=1
	AND ADMIT_FROM_SNF = 'Yes'
;

-- SELECT	*
-- FROM pbi.POST_ACUTE_CARE_DASHBOARD_HOSP_VISITS
-- ORDER BY PAT_NAME, ICN, HOSP_ADMSN_TIME
-- ;


END
GO
