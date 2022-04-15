/*
Company: OptimaJet
Project: WorkflowServer Oracle
Version: 2
File: WorkflowServerScripts.sql
*/

CREATE TABLE WORKFLOWSERVERSTATS (
                                     ID RAW(16),
                                     TYPE NVARCHAR2(256) NOT NULL,
                                     DATEFROM DATE NOT NULL,
                                     DATETO DATE NOT NULL,
                                     DURATION NUMBER NOT NULL,
                                     ISSUCCESS CHAR(1 BYTE) NOT NULL,
  PROCESSID RAW(16) NULL,
  CONSTRAINT PK_WORKFLOWSERVERSTATS PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64K NEXT 1M MAXEXTENTS UNLIMITED ))
    LOGGING;
--eos

CREATE INDEX IDX_WORKFLOWSERVERSTATS_PROCESSID ON WORKFLOWSERVERSTATS (PROCESSID)
    LOGGING;
--eos

CREATE TABLE WORKFLOWSERVERPROCESSHISTORY (
                                              ID RAW(16),
                                              PROCESSID RAW(16) NOT NULL,
                                              IDENTITYID NVARCHAR2(256) NULL,
                                              ALLOWEDTOEMPLOYEENAMES NCLOB NULL,
                                              TRANSITIONTIME DATE NULL,
                                              "Order" NUMBER GENERATED ALWAYS AS IDENTITY,
                                              INITIALSTATE NVARCHAR2(1024) NOT NULL,
                                              DESTINATIONSTATE NVARCHAR2(1024) NOT NULL,
                                              COMMAND NVARCHAR2(1024) NOT NULL,
                                              CONSTRAINT PK_WORKFLOWSERVERPROCESSHISTORY PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64K NEXT 1M MAXEXTENTS UNLIMITED ))
    LOGGING;
--eos

CREATE INDEX IDX_WORKFLOWSERVERPROCESSHISTORY_PROCESSID ON WORKFLOWSERVERPROCESSHISTORY (PROCESSID)
    LOGGING;
--eos

ALTER TABLE WORKFLOWINBOX MODIFY IDENTITYID NVARCHAR2(1024);
--eos

CREATE OR REPLACE TYPE TREPORTBYSCHEMEENTRY AS OBJECT ( 
    CODE VARCHAR2(1024),
    PROCESSCOUNT NUMBER,
    TRANSITIONCOUNT NUMBER
);
--eos

CREATE OR REPLACE TYPE TREPORTBYSCHEME AS TABLE OF TREPORTBYSCHEMEENTRY;
--eos

CREATE OR REPLACE FUNCTION WORKFLOWREPORTBYSCHEMES
    RETURN TREPORTBYSCHEME
AS
    ResultReport TREPORTBYSCHEME;
begin
SELECT
    TREPORTBYSCHEMEENTRY(ws.CODE,
                         (SELECT COUNT(inst.ID) FROM WORKFLOWPROCESSINSTANCE inst
                                                         LEFT JOIN WORKFLOWPROCESSSCHEME ps on ps.ID = inst.SCHEMEID
                          WHERE coalesce(ps.ROOTSCHEMECODE, ps.SCHEMECODE) = ws.CODE),
                         (SELECT COUNT(history.ID) FROM WORKFLOWPROCESSTRANSITIONH history
                                                            LEFT JOIN WORKFLOWPROCESSINSTANCE inst on history.PROCESSID = inst.ID
                                                            LEFT JOIN WORKFLOWPROCESSSCHEME ps on ps.ID = inst.SCHEMEID
                          WHERE coalesce(ps.ROOTSCHEMECODE, ps.SCHEMECODE) = ws.CODE))
        BULK COLLECT INTO ResultReport
FROM WORKFLOWSCHEME ws;

RETURN ResultReport;
end;
--eof

CREATE OR REPLACE TYPE TREPORTBYTRANSITIONSENTRY AS OBJECT ( 
    "Date" DATE,
    SCHEMECODE VARCHAR2(1024),
    COUNT NUMBER
);
--eos

CREATE OR REPLACE TYPE TREPORTBYTRANSITIONS AS TABLE OF TREPORTBYTRANSITIONSENTRY;
--eos

CREATE OR REPLACE TYPE TREPORTENTRY AS OBJECT (df DATE, de DATE);
--eos

CREATE OR REPLACE TYPE TREPORT AS TABLE OF TREPORTENTRY;
--eos

CREATE OR REPLACE FUNCTION WORKFLOWREPORTBYTRANSITIONS(datefrom DATE, dateto DATE, period NUMBER)
    RETURN TREPORTBYTRANSITIONS
AS
    ResultReport TREPORTBYTRANSITIONS;
    ReportTmp TREPORT := TREPORT();
    curdate DATE;
    dateend DATE;
BEGIN

	IF datefrom > dateto THEN
		RETURN NULL;
END IF;

	curdate := TRUNC(datefrom, 'MM');
	if period >= 1 then 
		curdate := curdate + (EXTRACT(DAY FROM datefrom) - 1);
end if;
	if period >= 2 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'HH24')) / 24;
end if;
	if period >= 3 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'MI')) / (24 * 60);
end if;
	if period >= 4 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'SS')) / (24 * 60 * 60);
end if;

	WHILE curdate <= dateto LOOP
		dateend := CASE 
			WHEN period = 0 then ADD_MONTHS(curdate, 1)
			WHEN period = 1 THEN curdate + 1
			WHEN period = 2 THEN curdate + 1 / 24
			WHEN period = 3 THEN curdate + 1 / (24 * 60)
			WHEN period = 4 THEN curdate + 1 / (24 * 60 * 60)
end;
        
        ReportTmp.EXTEND(1);
        ReportTmp(ReportTmp.LAST) := TREPORTENTRY(curdate, dateend);
                
		curdate := dateend;
END LOOP;

SELECT TREPORTBYTRANSITIONSENTRY(
               p.df,
               scheme.CODE,
               coalesce(COUNT(history.ID), 0))
           BULK COLLECT INTO ResultReport
FROM TABLE(ReportTmp) p
         LEFT JOIN WORKFLOWSCHEME scheme on 1=1
         LEFT JOIN WORKFLOWPROCESSSCHEME ps on scheme.CODE = coalesce(ps.ROOTSCHEMECODE, ps.SCHEMECODE)
         LEFT JOIN WORKFLOWPROCESSINSTANCE inst on ps.ID = inst.SCHEMEID
         LEFT JOIN WORKFLOWPROCESSTRANSITIONH history on history.PROCESSID = inst.ID AND history.TRANSITIONTIME >= p.df AND history.TRANSITIONTIME < p.de
GROUP BY p.df, scheme.CODE
ORDER BY p.df, scheme.CODE;

RETURN ResultReport;

end;
--eof

CREATE OR REPLACE TYPE TREPORTBYSTATSENTRY AS OBJECT ( "Date" timestamp, 
    SCHEMECODE NVARCHAR2(1024), 
    TYPE NVARCHAR2(1024), 
    ISSUCCESS CHAR(1 BYTE),
    COUNT NUMBER,
    DURATIONAVG NUMBER,
    DURATIONMIN NUMBER,
    DURATIONMAX NUMBER
);
--eos

CREATE OR REPLACE TYPE TREPORTBYSTATS AS TABLE OF TREPORTBYSTATSENTRY;
--eos

CREATE OR REPLACE TYPE TCODES AS TABLE OF NVARCHAR2(1024);
--eos

CREATE OR REPLACE TYPE TSTATSUCCESS AS TABLE OF CHAR(1 BYTE);
--eos

CREATE OR REPLACE FUNCTION WORKFLOWREPORTBYSTATS(datefrom DATE, dateto DATE, period NUMBER)
RETURN TREPORTBYSTATS
AS
    ResultReport TREPORTBYSTATS;
    curdate DATE;
    dateend DATE;
    ReportTmp TREPORT := TREPORT();
    SchemesTmp TCODES;
    TypesTmp TCODES;
    SuccessesTmp TSTATSUCCESS := TSTATSUCCESS(0, 1);
BEGIN

	IF datefrom > dateto THEN
		RETURN NULL;
END IF;

	curdate := TRUNC(datefrom, 'MM');
	if period >= 1 then 
		curdate := curdate + (EXTRACT(DAY FROM datefrom) - 1);
end if;
	if period >= 2 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'HH24')) / 24;
end if;
	if period >= 3 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'MI')) / (24 * 60);
end if;
	if period >= 4 then 
		curdate := curdate + TO_NUMBER(TO_CHAR(datefrom, 'SS')) / (24 * 60 * 60);
end if;

	WHILE curdate <= dateto LOOP
		dateend := CASE 
			WHEN period = 0 then ADD_MONTHS(curdate, 1)
			WHEN period = 1 THEN curdate + 1
			WHEN period = 2 THEN curdate + 1 / 24
			WHEN period = 3 THEN curdate + 1 / (24 * 60)
			WHEN period = 4 THEN curdate + 1 / (24 * 60 * 60)
end;

        ReportTmp.EXTEND(1);
        ReportTmp(ReportTmp.LAST) := TREPORTENTRY(curdate, dateend);
        
		curdate := dateend;
END LOOP;

SELECT DISTINCT coalesce(ps.ROOTSCHEMECODE, ps.SCHEMECODE)
                    BULK COLLECT into SchemesTmp
FROM WORKFLOWSERVERSTATS stats
         LEFT JOIN WORKFLOWPROCESSINSTANCE inst on inst.ID = stats.PROCESSID
         LEFT JOIN WORKFLOWPROCESSSCHEME ps on inst.SCHEMEID = ps.ID
WHERE DATEFROM >= datefrom AND DATEFROM < dateto;


SELECT DISTINCT stats.TYPE
                    BULK COLLECT into TypesTmp
FROM WORKFLOWSERVERSTATS stats
WHERE stats.DATEFROM >= datefrom AND stats.DATEFROM < dateto;

SELECT TREPORTBYSTATSENTRY(
               p.df,
               scheme.column_value,
               types.column_value,
               success.column_value,
               coalesce(COUNT(stats.ID), 0),
               coalesce(AVG(stats.DURATION), 0),
               coalesce(MIN(stats.DURATION), 0),
               coalesce(MAX(stats.DURATION), 0))
           BULK COLLECT INTO ResultReport
FROM TABLE(ReportTmp) p
         LEFT JOIN TABLE(SchemesTmp) scheme on 1=1
         LEFT JOIN TABLE(TypesTmp) types on 1=1
         LEFT JOIN TABLE(SuccessesTmp) success on 1=1
         LEFT JOIN WORKFLOWSERVERSTATS stats on stats.TYPE = types.column_value AND stats.ISSUCCESS = success.column_value AND stats.DATEFROM >= p.df AND stats.DATEFROM < p.de
         LEFT JOIN WORKFLOWPROCESSINSTANCE inst on stats.PROCESSID = inst.ID
         LEFT JOIN WORKFLOWPROCESSSCHEME ps on ps.ID = inst.SCHEMEID AND scheme.column_value = coalesce(ps.ROOTSCHEMECODE, ps.SCHEMECODE)
GROUP BY p.df, scheme.column_value, types.column_value, success.column_value
ORDER BY p.df, scheme.column_value, types.column_value, success.column_value;

RETURN ResultReport;

end;
--eof

ALTER TABLE WORKFLOWSCHEME ADD DELETEFINALIZED CHAR(1 BYTE) DEFAULT 0 NOT NULL;
--eos

ALTER TABLE WORKFLOWSCHEME ADD DONTFILLINDOX CHAR(1 BYTE) DEFAULT 0 NOT NULL;
--eos

ALTER TABLE WORKFLOWSCHEME ADD DONTPREEXECUTE CHAR(1 BYTE) DEFAULT 0 NOT NULL;
--eos

ALTER TABLE WORKFLOWSCHEME ADD AUTOSTART CHAR(1 BYTE) DEFAULT 0 NOT NULL;
--eos

ALTER TABLE WORKFLOWSCHEME ADD DEFAULTFORM NVARCHAR2(1024) NULL;
--eos

CREATE TABLE WORKFLOWSERVERLOGS (
                                    ID RAW(16),
                                    MESSAGE NCLOB NOT NULL,
                                    MESSAGETEMPLATE NCLOB NOT NULL,
                                    TIMESTAMP DATE NOT NULL,
                                    EXCEPTION NCLOB NULL,
                                    PROPERTIESJSON NCLOB NULL,
                                    LOGLEVEL NUMBER(3) NOT NULL,
                                    RUNTIMEID NVARCHAR2(900) NOT NULL,
                                    CONSTRAINT PK_WORKFLOWSERVERLOGS PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64K NEXT 1M MAXEXTENTS UNLIMITED ))
    LOGGING;
--eos

CREATE INDEX IDX_WORKFLOWSERVERLOGS_TIMESTAMP ON WORKFLOWSERVERLOGS (TIMESTAMP)
    LOGGING;
--eos

CREATE INDEX IDX_WORKFLOWSERVERLOGS_LEVEL ON WORKFLOWSERVERLOGS (LOGLEVEL)
    LOGGING;
--eos

CREATE INDEX IDX_RUNTIMEID_LEVEL ON WORKFLOWSERVERLOGS (RUNTIMEID)
    LOGGING;
--eos

CREATE TABLE WORKFLOWSERVERUSER(
                                   ID         RAW(16),
                                   NAME       NVARCHAR2(256)         NOT NULL,
                                   EMAIL      NVARCHAR2(256)         NULL,
                                   PHONE      NVARCHAR2(256)         NULL,
                                   ISLOCKED   CHAR(1 BYTE) DEFAULT 0 NOT NULL,
    EXTERNALID NVARCHAR2(1024)        NULL,
    LOCKFLAG   RAW(16)                NOT NULL,
    TENANTID   NVARCHAR2(1024)        NULL,
    ROLES      NCLOB                  NULL,
    EXTENSIONS NCLOB                  NULL,
    CONSTRAINT PK_WORKFLOWSERVERUSER PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64 K NEXT 1 M MAXEXTENTS UNLIMITED )
)
    LOGGING;
--eos

CREATE TABLE WORKFLOWSERVERUSERCREDENTIAL(
                                             ID                   RAW(16),
                                             PASSWORDHASH         NVARCHAR2(128)  NULL,
                                             PASSWORDSALT         NVARCHAR2(128)  NULL,
                                             USERID               RAW(16)         NOT NULL,
                                             LOGIN                NVARCHAR2(256)  NOT NULL,
                                             AUTHTYPE             NUMBER(3)       NOT NULL,
                                             TENANTID             NVARCHAR2(1024) NULL,
                                             EXTERNALPROVIDERNAME NVARCHAR2(128)  NULL,
                                             CONSTRAINT FK_WORKFLOWSERVERUSER_WORKFLOWSERVERUSERCREDENTIAL FOREIGN KEY (USERID)
                                                 REFERENCES WORKFLOWSERVERUSER (ID) ON DELETE CASCADE,
                                             CONSTRAINT PK_WORKFLOWSERVERUSERCREDENTIAL PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64 K NEXT 1 M MAXEXTENTS UNLIMITED )
)
    LOGGING;
--eos

CREATE INDEX IX_WORKFLOWSERVERUSERCREDENTIAL_USERID ON WORKFLOWSERVERUSERCREDENTIAL (USERID);
--eos

CREATE INDEX IX_WORKFLOWSERVERUSERCREDENTIAL_LOGIN ON WORKFLOWSERVERUSERCREDENTIAL (LOGIN);
--eos

CREATE TABLE WORKFLOWSERVERPROCESSLOGS(
                                          ID         RAW(16),
                                          PROCESSID  RAW(16)                             NOT NULL,
                                          CREATEDON  TIMESTAMP default current_timestamp NOT NULL,
                                          TIMESTAMP  TIMESTAMP default current_timestamp NOT NULL,
                                          SCHEMECODE NVARCHAR2(256)                      NULL,
                                          MESSAGE    NCLOB     DEFAULT ' '               NOT NULL,
                                          PROPERTIES NCLOB     DEFAULT ' '               NOT NULL,
                                          EXCEPTION  NCLOB     DEFAULT ' '               NOT NULL,
                                          TENANTID   NVARCHAR2(1024)                     NULL,
                                          CONSTRAINT PK_WORKFLOWSERVERPROCESSLOGS PRIMARY KEY (ID) USING INDEX STORAGE ( INITIAL 64 K NEXT 1 M MAXEXTENTS UNLIMITED )
)
    LOGGING;
--eos

CREATE INDEX IDX_WORKFLOWSERVERPROCESSLOGS_TIMESTAMP ON WORKFLOWSERVERPROCESSLOGS (TIMESTAMP);
--eos
CREATE INDEX IDX_WORKFLOWSERVERPROCESSLOGS_CREATEDON ON WORKFLOWSERVERPROCESSLOGS (CREATEDON);
--eos
CREATE INDEX IDX_WORKFLOWSERVERPROCESSLOGS_PROCESSID ON WORKFLOWSERVERPROCESSLOGS (PROCESSID);
--eos

COMMIT;
--eos
