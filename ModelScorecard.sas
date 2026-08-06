/**************************************************************************************************/
/*                                                                                                */
/*   Project : Credit Risk Scorecard - Fannie Mae Single-Family Loan Data                         */
/*   Program : CreditRiskScorecard_Modeling.sas                                                   */
/*   Author  : Anne M. Prihoda                                                                    */
/*                                                                                                */
/*   Purpose : Build and validate a loan-level credit risk scorecard                              */
/*                                                                                                */
/*             - Verify the loan-level data inherited from the ETL pipeline                       */
/*             - Reduce the master table to the modeling fields                                   */
/*             - Split by origination year into training and out-of-time validation               */
/*             - Bin each predictor and compute Weight of Evidence and Information Value          */
/*             - Fit the logistic regression and scale coefficients to scorecard points           */
/*             - Measure discrimination, calibration and population stability                     */
/*             - Publish the model development report as a PDF and as a web page                  */
/*                                                                                                */
/*   Input   : FNMAE.LoanMaster - built by ETLPipeline_CreditRiskScorecard.sas                    */
/*                                                                                                */
/*   Source  : Fannie Mae Single-Family Loan Performance Data, including the published            */
/*             Statistical Summary tables used to validate this build                             */
/*             https://capitalmarkets.fanniemae.com/credit-risk-transfer/                         */
/*             single-family-credit-risk-transfer/fannie-mae-single-family-loan-                  */
/*             performance-data                                                                   */
/*                                                                                                */
/*   Output  : MODEL  - model base, fitted model, scored validation                               */
/*             SCORE  - binning tables, Weight of Evidence formats, points table                  */
/*             REPORT - discrimination, calibration and stability results                         */
/*                                                                                                */
/*   Good    : A loan that did not default, DefaultFlag = 0                                       */
/*   Bad     : A loan that defaulted, DefaultFlag = 1                                             */
/*                                                                                                */
/**************************************************************************************************/


/**************************************************************************************************/
/*                                                                                                */
/*   Environment setup - base directory and library assignments                                   */
/*                                                                                                */
/**************************************************************************************************/

%LET root = /home/bvsierrap0;

OPTIONS dlcreatedir;

LIBNAME FNMAE  "&root/FNMAE"  COMPRESS=YES;
LIBNAME MODEL  "&root/MODEL"  COMPRESS=YES;
LIBNAME SCORE  "&root/SCORE"  COMPRESS=YES;
LIBNAME REPORT "&root/REPORT" COMPRESS=YES;


/**************************************************************************************************/
/*                                                                                                */
/*   Session_Log_Capture macro compartmentalizes the code that writes the SAS session log         */
/*   to ModelingSession.log. This is the session log, not FNMAE.RunLog                            */
/*   Option #1 - Create: starts a new log file, erasing any existing one. Starred -               */
/*               un-star once at the start of a new project log                                   */
/*   Option #2 - Continue: appends the current session log to the existing file, creating         */
/*               it if it does not exist                                                          */
/*   First step, run %Session_Log_Capture; at the start of every modeling session                 */
/*   The capture ends by itself when the SAS session closes                                       */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Session_Log_Capture;

    /*   Option #1 - Create: new log file, erasing any existing one   */
    *PROC PRINTTO LOG="&root/ModelingSession.log" NEW;
    *RUN;

    /*   Option #2 - Continue: append the current session log to the existing file   */
    FILENAME ModLog "&root/ModelingSession.log" MOD;
    PROC PRINTTO LOG=ModLog;
    RUN;

%MEND Session_Log_Capture;


/**************************************************************************************************/
/*                                                                                                */
/*   Validate_LoanMaster macro verifies the data inherited from the ETL pipeline before           */
/*   any modeling table is built                                                                  */
/*   Check #1 - Coverage and default rate by origination year against Fannie Mae published        */
/*              statistical summaries                                                             */
/*   Check #2 - Duplicate loan identifiers, which must be zero                                    */
/*   Coverage near 100 percent per vintage and default rates within a few basis points of         */
/*   published certifies the build. The 2007 vintage reads a few percent under because its        */
/*   tail was acquired in 2008, outside the ETL window                                            */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Validate_LoanMaster;

    /*   Published figures - Fannie Mae Statistical Summary, loan counts and dispositions   */
    /*   Assignment statements are used because a macro cannot generate DATALINES           */
    DATA WORK._Published;
        LENGTH OrigYear 8 PubLoans 8 PubDefaults 8;

        OrigYear = 1999;  PubLoans =  160137;  PubDefaults =   2024;  OUTPUT;
        OrigYear = 2000;  PubLoans = 1268238;  PubDefaults =  16424;  OUTPUT;
        OrigYear = 2001;  PubLoans = 3371986;  PubDefaults =  39162;  OUTPUT;
        OrigYear = 2002;  PubLoans = 3857369;  PubDefaults =  48902;  OUTPUT;
        OrigYear = 2003;  PubLoans = 5107633;  PubDefaults =  84360;  OUTPUT;
        OrigYear = 2004;  PubLoans = 1744562;  PubDefaults =  56147;  OUTPUT;
        OrigYear = 2005;  PubLoans = 1446003;  PubDefaults =  86398;  OUTPUT;
        OrigYear = 2006;  PubLoans = 1080650;  PubDefaults =  88595;  OUTPUT;
        OrigYear = 2007;  PubLoans = 1252409;  PubDefaults = 112186;  OUTPUT;
    RUN;

    DATA WORK._Published;
        SET WORK._Published;
        PubRate = PubDefaults / PubLoans;
    RUN;

    /*   Check #1 - coverage and default rate by origination year   */
    PROC SQL;
        TITLE "LoanMaster Reconciliation to Fannie Mae Published Statistics";
        SELECT m.OrigYear               LABEL="Orig year",
               count(*)                 AS Loans    FORMAT=COMMA12. LABEL="Loans (mine)",
               p.PubLoans                            FORMAT=COMMA12. LABEL="Loans (published)",
               calculated Loans / p.PubLoans AS Coverage FORMAT=PERCENT8.1 LABEL="Coverage",
               mean(m.DefaultFlag)      AS DefRate  FORMAT=PERCENT8.2 LABEL="Default rate (mine)",
               p.PubRate                             FORMAT=PERCENT8.2 LABEL="Default rate (published)"
        FROM FNMAE.LoanMaster m
        LEFT JOIN WORK._Published p ON m.OrigYear = p.OrigYear
        GROUP BY m.OrigYear, p.PubLoans, p.PubRate;

        /*   Check #2 - duplicate loan identifiers   */
        TITLE "Duplicate Loan Check - Must Be Zero";
        SELECT count(*) - count(DISTINCT LoanIdentifier) AS DupLoans FORMAT=COMMA12.
        FROM FNMAE.LoanMaster;
    QUIT;

    TITLE;

%MEND Validate_LoanMaster;

%Validate_LoanMaster;


/**************************************************************************************************/
/*                                                                                                */
/*   Compress_LoanMaster macro rewrites LoanMaster with binary compression, which suits a         */
/*   mostly numeric table better than the character compression it was built with, and            */
/*   reclaims the dead space left by any replaced quarters                                        */
/*   Run once, before Build_ModelBase, if the home directory is short of space                    */
/*   The rewrite is staged through WORK because WORK sits outside the 5 GB home quota -           */
/*   rewriting in place would need room for both copies at once                                   */
/*   Step 1 writes the compressed copy, Step 2 swaps it in. Check the log after Step 1:           */
/*   the observation count must read 19,144,733 before running Step 2                             */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Compress_LoanMaster_Step1;

    DATA WORK.LoanMasterBin (COMPRESS=BINARY);
        SET FNMAE.LoanMaster;
    RUN;

%MEND Compress_LoanMaster_Step1;

/*   Run Step 1 by itself. Read the log: it must report 19,144,733 observations written      */
/*   to WORK.LoanMasterBin before Step 2 deletes anything                                    */
%Compress_LoanMaster_Step1;


%MACRO Compress_LoanMaster_Step2;

    PROC DATASETS LIBRARY=FNMAE NOLIST;
        DELETE LoanMaster;
    QUIT;

    PROC DATASETS LIBRARY=WORK NOLIST;
        COPY OUT=FNMAE MOVE;
        SELECT LoanMasterBin;
    QUIT;

    PROC DATASETS LIBRARY=FNMAE NOLIST;
        CHANGE LoanMasterBin = LoanMaster;
    QUIT;

%MEND Compress_LoanMaster_Step2;

/*   Only after the log confirms 19,144,733 observations                                          */
%Compress_LoanMaster_Step2;

/**************************************************************************************************/
/**************************************************************************************************/
/**************************************************************************************************/ 

/**************************************************************************************************/
/*                                                                                                */
/*   Build_ModelBase macro reduces LoanMaster to the modeling fields                              */
/*   Keeps only what was knowable at origination - outcome fields would make the model            */
/*   circular - and shortens numeric storage from 8 bytes to the width each field needs           */
/*   Incoming numerics are read under temporary names and assigned across, so the shortened       */
/*   lengths are applied deliberately with no truncation warnings                                 */
/*   COMPRESS=NO because short numerics compress poorly                                           */
/*   The build is staged through WORK because WORK sits outside the 5 GB home quota, so a         */
/*   large write cannot run the home directory out of space                                       */
/*   Step 1 builds the table, Step 2 moves it into MODEL. Check the log after Step 1: the         */
/*   observation count must read 19,144,733 before running Step 2                                 */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Build_ModelBase_Step1;

    DATA WORK.ModelBaseTemp (COMPRESS=NO);
        LENGTH
            LoanIdentifier                  $12
            DefaultFlag                       3
            OrigYear                          3
            FICO                              3
            LTV                               3
            CLTV                              3
            DTI                               3
            NumBorrower                       3
            NumUnits                          3
            OrigLoanTerm                      3
            MortgInsPrct                      3
            OrigUPB                           5
            NoteRate                          8
            Channel                          $1
            LoanPurpose                      $1
            OccupancyStatus                  $1
            PropertyType                     $2
            FirstTimeBuyer                   $1
            PropertyState                    $2
        ;

        SET FNMAE.LoanMaster
            (KEEP = LoanIdentifier DefaultFlag OrigYear
                    FICO LTV CLTV DTI
                    NumBorrower NumUnits OrigLoanTerm
                    MortgInsPrct OrigUPB
                    NoteRate Channel LoanPurpose
                    OccupancyStatus PropertyType
                    FirstTimeBuyer PropertyState
             RENAME = (DefaultFlag  = _DefaultFlag
                       OrigYear     = _OrigYear
                       FICO         = _FICO
                       LTV          = _LTV
                       CLTV         = _CLTV
                       DTI          = _DTI
                       NumBorrower  = _NumBorrower
                       NumUnits     = _NumUnits
                       OrigLoanTerm = _OrigLoanTerm
                       MortgInsPrct = _MortgInsPrct
                       OrigUPB      = _OrigUPB));

        DefaultFlag  = _DefaultFlag;
        OrigYear     = _OrigYear;
        FICO         = _FICO;
        LTV          = _LTV;
        CLTV         = _CLTV;
        DTI          = _DTI;
        NumBorrower  = _NumBorrower;
        NumUnits     = _NumUnits;
        OrigLoanTerm = _OrigLoanTerm;
        MortgInsPrct = _MortgInsPrct;
        OrigUPB      = _OrigUPB;

        DROP _DefaultFlag _OrigYear _FICO _LTV _CLTV _DTI
             _NumBorrower _NumUnits _OrigLoanTerm _MortgInsPrct _OrigUPB;
    RUN;

%MEND Build_ModelBase_Step1;

/*   Run Step 1 by itself. Read the log: it must report 19,144,733 observations written      */
/*   to WORK.ModelBaseTemp before Step 2 moves anything                                      */
%Build_ModelBase_Step1;



%MACRO Build_ModelBase_Step2;

    PROC DATASETS LIBRARY=WORK NOLIST;
        COPY OUT=MODEL MOVE;
        SELECT ModelBaseTemp;
    QUIT;

    PROC DATASETS LIBRARY=MODEL NOLIST;
        CHANGE ModelBaseTemp = ModelBase;
    QUIT;

%MEND Build_ModelBase_Step2;

/*   Only after the log confirms 19,144,733 observations                                     */
%Build_ModelBase_Step2;



/**************************************************************************************************/
/*                                                                                                */
/*   Split_Train_Valid macro splits by origination year, not randomly                             */
/*   Training   - 2000 to 2005 originations                                                       */
/*   Validation - 2006 to 2007 originations, seasoned through the crisis                          */
/*   Both are views over ModelBase - filters, not copies, so they cost no disk                    */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Split_Train_Valid;

    PROC SQL;
        CREATE VIEW MODEL.Train AS
            SELECT * FROM MODEL.ModelBase WHERE 2000 <= OrigYear <= 2005;

        CREATE VIEW MODEL.Valid AS
            SELECT * FROM MODEL.ModelBase WHERE 2006 <= OrigYear <= 2007;
    QUIT;

    PROC SQL;
        TITLE "Training and Validation Samples";
        SELECT "Train" AS Sample LABEL="Sample",
               count(*) AS Loans FORMAT=COMMA12. LABEL="Loans",
               mean(DefaultFlag) AS DefRate FORMAT=PERCENT8.2 LABEL="Default rate"
        FROM MODEL.Train
        UNION
        SELECT "Valid", count(*) FORMAT=COMMA12., mean(DefaultFlag) FORMAT=PERCENT8.2
        FROM MODEL.Valid;
    QUIT;

    TITLE;

%MEND Split_Train_Valid;


/**************************************************************************************************/
/*                                                                                                */
/*   Woe_OneVariable macro builds the bin table for a single predictor                            */
/*   Called by %FineClass_Woe once per variable - not run on its own                              */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Woe_OneVariable(Rank=, Raw=, Out=);

    %LOCAL TotGood TotBad;

    PROC MEANS DATA=WORK.Fine NOPRINT NWAY;
        CLASS &Rank;
        VAR DefaultFlag &Raw;
        OUTPUT OUT=SCORE.&Out
               n(DefaultFlag)   = NLoans
               sum(DefaultFlag) = NBad
               min(&Raw)        = RawMin
               max(&Raw)        = RawMax;
    RUN;

    PROC SQL NOPRINT;
        SELECT sum(NLoans - NBad), sum(NBad)
          INTO :TotGood trimmed, :TotBad trimmed
        FROM SCORE.&Out;
    QUIT;

    DATA SCORE.&Out;
        SET SCORE.&Out;
        NGood   = NLoans - NBad;
        PctGood = NGood / &TotGood;
        PctBad  = NBad  / &TotBad;
        IF NBad > 0 AND NGood > 0 THEN Woe = log(PctGood / PctBad);
        ELSE Woe = .;
        IvPart = (PctGood - PctBad) * Woe;
        FORMAT PctGood PctBad PERCENT8.2 Woe IvPart 8.4;
        DROP _TYPE_ _FREQ_;
    RUN;

    PROC PRINT DATA=SCORE.&Out NOOBS LABEL;
        TITLE "Fine Bins for &Raw - Weight of Evidence Should Move in One Direction";
        VAR &Rank RawMin RawMax NLoans NBad Woe IvPart;
        LABEL &Rank="Bin" RawMin="From" RawMax="To" NLoans="Loans"
              NBad="Defaults" Woe="WOE" IvPart="IV contribution";
    RUN;

    PROC SQL;
        TITLE "Information Value for &Raw";
        SELECT sum(IvPart) AS IV FORMAT=8.4 LABEL="Information Value"
        FROM SCORE.&Out;
    QUIT;

    TITLE;

%MEND Woe_OneVariable;


/**************************************************************************************************/
/*                                                                                                */
/*   FineClass_Woe macro cuts each predictor into 20 ranked groups on the training data,          */
/*   counts goods and bads per group, and computes Weight of Evidence and Information Value       */
/*   WOE = ln(percent of goods / percent of bads): positive is safer than average                 */
/*   IV  = sum over bins of (percent goods - percent bads) x WOE                                  */
/*   Inspect each table for monotonic WOE before choosing coarse class cut points                 */
/*                                                                                                */
/**************************************************************************************************/

%MACRO FineClass_Woe;

    PROC RANK DATA=MODEL.Train OUT=WORK.Fine GROUPS=20;
        VAR FICO LTV DTI OrigUPB NoteRate;
        RANKS RFico RLtv RDti RUpb RRate;
    RUN;

    %Woe_OneVariable(Rank=RFico, Raw=FICO,     Out=FicoBins);
    %Woe_OneVariable(Rank=RLtv,  Raw=LTV,      Out=LtvBins);
    %Woe_OneVariable(Rank=RDti,  Raw=DTI,      Out=DtiBins);
    %Woe_OneVariable(Rank=RUpb,  Raw=OrigUPB,  Out=UpbBins);
    %Woe_OneVariable(Rank=RRate, Raw=NoteRate, Out=RateBins);

%MEND FineClass_Woe;

/**************************************************************************************************/
/*                                                                                                */
/*   Run to here first. Read the fine bin tables and Information Values, choose the coarse        */
/*   class cut points, then complete %CoarseClass_Formats below before going further              */
/*                                                                                                */
/**************************************************************************************************/

%Split_Train_Valid;

%FineClass_Woe;



/**************************************************************************************************/
/*                                                                                                */
/*   CoarseClass_Formats macro holds the final bin cut points as PROC FORMAT ranges               */
/*   Values computed from the fine bin tables produced by %FineClass_Woe on the 2000 to 2005      */
/*   training sample, 16.8 million loans at a 1.96 percent default rate                           */
/*   Every class holds at least 5 percent of the sample and Weight of Evidence moves in one       */
/*   direction across all classes                                                                 */
/*   Cut points come from the training data only and are never recomputed on validation           */
/*                                                                                                */
/**************************************************************************************************/

%MACRO CoarseClass_Formats;

    PROC FORMAT;

        /*   FICO - 10 classes, IV 0.5234, WOE -0.9041 to 1.3341   */
        value woe_fico
            low  - 619  = -0.9041
            620  - 656  = -0.8237
            657  - 680  = -0.5716
            681  - 700  = -0.2737
            701  - 718  = -0.0094
            719  - 736  =  0.2604
            737  - 752  =  0.5593
            753  - 765  =  0.8291
            766  - 779  =  1.1297
            780  - high =  1.3341
            other       =  0;

        /*   LTV - 9 classes, IV 0.4840. LTV exactly 80 is its own class because borrowers     */
        /*   who put 20 percent down to avoid mortgage insurance are a distinct population     */
        value woe_ltv
            low  - 43   =  2.0554
            44   - 54   =  1.3212
            55   - 62   =  0.7757
            63   - 69   =  0.3166
            70   - 79   = -0.0406
            80   - 80   = -0.2582
            81   - 89   = -0.5849
            90   - 94   = -0.7353
            95   - high = -0.8508
            other       =  0;

        /*   DTI - 6 classes, IV 0.1357   */
        value woe_dti
            low  - 19   =  0.6807
            20   - 25   =  0.4392
            26   - 32   =  0.1615
            33   - 37   = -0.0843
            38   - 44   = -0.2870
            45   - high = -0.3970
            other       =  0;

    RUN;

%MEND CoarseClass_Formats;


/**************************************************************************************************/
/*                                                                                                */
/*   Apply_Woe macro replaces each raw value with the Weight of Evidence of its bin               */
/*   The same formats are applied to training and validation - validation is never re-binned      */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Apply_Woe;

    DATA MODEL.TrainWoe;
        SET MODEL.Train;
        WoeFico = INPUT(PUT(FICO, woe_fico.), BEST12.);
        WoeLtv  = INPUT(PUT(LTV,  woe_ltv.),  BEST12.);
        WoeDti  = INPUT(PUT(DTI,  woe_dti.),  BEST12.);
    RUN;

    DATA MODEL.ValidWoe;
        SET MODEL.Valid;
        WoeFico = INPUT(PUT(FICO, woe_fico.), BEST12.);
        WoeLtv  = INPUT(PUT(LTV,  woe_ltv.),  BEST12.);
        WoeDti  = INPUT(PUT(DTI,  woe_dti.),  BEST12.);
    RUN;

%MEND Apply_Woe;


/**************************************************************************************************/
/*                                                                                                */
/*   Fit_Model macro fits the logistic regression on the Weight of Evidence variables             */
/*   Models the log odds of default, so the prediction stays between 0 and 1                      */
/*   OUTMODEL saves the fitted model so validation can be scored without refitting                */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Fit_Model;

    PROC LOGISTIC DATA=MODEL.TrainWoe OUTMODEL=MODEL.PdModel;
        TITLE "Model Fit - Training Sample";
        MODEL DefaultFlag(EVENT='1') = WoeFico WoeLtv WoeDti
              / OUTROC=REPORT.RocTrain;
        ODS OUTPUT ParameterEstimates=MODEL.Coefficients;
    RUN;

    TITLE;

%MEND Fit_Model;

/**************************************************************************************************/
/*                                                                                                */
/*   Run to here next. Read the parameter estimates, then complete %Points_Scorecard below        */
/*   before going further                                                                         */
/*                                                                                                */
/**************************************************************************************************/

%CoarseClass_Formats;

%Apply_Woe;

%Fit_Model;


/**************************************************************************************************/
/*                                                                                                */
/*   Points_Scorecard macro converts the model coefficients into scorecard points                 */
/*   Base 600 points at 50 to 1 odds, 20 points to double the odds                                */
/*   factor = PDO / ln(2), offset = base - factor x ln(base odds)                                 */
/*   Points per class = -(coefficient x WOE + intercept / n) x factor + offset / n                */
/*   Coefficients come from MODEL.Coefficients, so the table rebuilds itself whenever the         */
/*   model is refitted - nothing is typed in by hand                                              */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Points_Scorecard(Pdo=20, BasePoints=600, BaseOdds=50, NVars=3);

    %LOCAL Factor Offset;
    %LET Factor = %SYSEVALF(&Pdo / 0.6931472);
    %LET Offset = %SYSEVALF(&BasePoints - &Factor * %SYSFUNC(LOG(&BaseOdds)));

    /*   The coarse classes and their Weight of Evidence, as applied by %CoarseClass_Formats   */
    /*   Assignment statements are used because a macro cannot generate DATALINES              */
    DATA WORK._Classes;
        LENGTH Characteristic $14 Bin $14 Variable $8 Woe 8 SortKey 3;

        /*   SortKey orders the printed table by predictive strength, strongest first   */

        Characteristic="Credit score"; Bin="below 620"; Woe=-0.9041; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="620 to 656"; Woe=-0.8237; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="657 to 680"; Woe=-0.5716; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="681 to 700"; Woe=-0.2737; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="701 to 718"; Woe=-0.0094; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="719 to 736"; Woe= 0.2604; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="737 to 752"; Woe= 0.5593; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="753 to 765"; Woe= 0.8291; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="766 to 779"; Woe= 1.1297; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="Credit score"; Bin="780 and above"; Woe= 1.3341; Variable="WoeFico"; SortKey=1; OUTPUT;
        Characteristic="LTV"; Bin="43 and below"; Woe= 2.0554; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="44 to 54"; Woe= 1.3212; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="55 to 62"; Woe= 0.7757; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="63 to 69"; Woe= 0.3166; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="70 to 79"; Woe=-0.0406; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="exactly 80"; Woe=-0.2582; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="81 to 89"; Woe=-0.5849; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="90 to 94"; Woe=-0.7353; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="LTV"; Bin="95 and above"; Woe=-0.8508; Variable="WoeLtv"; SortKey=2; OUTPUT;
        Characteristic="DTI"; Bin="19 and below"; Woe= 0.6807; Variable="WoeDti"; SortKey=3; OUTPUT;
        Characteristic="DTI"; Bin="20 to 25"; Woe= 0.4392; Variable="WoeDti"; SortKey=3; OUTPUT;
        Characteristic="DTI"; Bin="26 to 32"; Woe= 0.1615; Variable="WoeDti"; SortKey=3; OUTPUT;
        Characteristic="DTI"; Bin="33 to 37"; Woe=-0.0843; Variable="WoeDti"; SortKey=3; OUTPUT;
        Characteristic="DTI"; Bin="38 to 44"; Woe=-0.2870; Variable="WoeDti"; SortKey=3; OUTPUT;
        Characteristic="DTI"; Bin="45 and above"; Woe=-0.3970; Variable="WoeDti"; SortKey=3; OUTPUT;
    RUN;


    /*   Intercept and slope coefficients from the fitted model   */
    PROC SQL NOPRINT;
        SELECT Estimate INTO :Intercept trimmed
        FROM MODEL.Coefficients
        WHERE Variable = "Intercept";
    QUIT;

    PROC SQL;
        CREATE TABLE SCORE.Points AS
        SELECT c.Characteristic          LABEL="Characteristic",
               c.Bin                     LABEL="Class",
               c.Woe                     FORMAT=8.4 LABEL="WOE",
               b.Estimate                FORMAT=8.4 LABEL="Coefficient",
               round(-(b.Estimate * c.Woe + &Intercept / &NVars) * &Factor
                     + &Offset / &NVars)  AS Points FORMAT=6. LABEL="Points",
               c.SortKey
        FROM WORK._Classes c
        INNER JOIN MODEL.Coefficients b ON c.Variable = b.Variable
        ORDER BY c.SortKey, c.Woe DESC;
    QUIT;

    /*   Coefficient is kept in the table but not printed - it repeats down each block   */
    PROC PRINT DATA=SCORE.Points NOOBS LABEL;
        TITLE "Credit Risk Scorecard - Points by Characteristic and Class";
        TITLE2 "Base &BasePoints points at &BaseOdds to 1 odds, &Pdo points to double the odds";
        VAR Characteristic Bin Woe Points;
    RUN;

    TITLE;

%MEND Points_Scorecard;



/**************************************************************************************************/
/*                                                                                                */
/*   Score_Validation macro scores the out-of-time sample with the fitted model and               */
/*   measures discrimination                                                                      */
/*   KS   - widest gap between cumulative bads captured and cumulative goods captured             */
/*   AUC  - probability a random defaulter scores riskier than a random non-defaulter             */
/*   Gini - 2 x AUC - 1                                                                           */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Score_Validation;

    PROC LOGISTIC INMODEL=MODEL.PdModel;
        SCORE DATA=MODEL.ValidWoe OUT=MODEL.ValidScored
              OUTROC=REPORT.RocValid FITSTAT;
    RUN;

    PROC SQL;
        CREATE TABLE REPORT.KsSummary AS
        SELECT "Training"   AS Sample LABEL="Sample",
               max(_SENSIT_ - _1MSPEC_) AS KS FORMAT=PERCENT8.2 LABEL="KS"
        FROM REPORT.RocTrain
        UNION
        SELECT "Validation", max(_SENSIT_ - _1MSPEC_) FORMAT=PERCENT8.2
        FROM REPORT.RocValid;

        TITLE "Discrimination - Training versus Out-of-Time Validation";
        SELECT * FROM REPORT.KsSummary;
    QUIT;

    TITLE;

%MEND Score_Validation;


/**************************************************************************************************/
/*                                                                                                */
/*   Calibration_Check macro compares predicted default rates with actual, by score band and      */
/*   by origination year                                                                          */
/*   Discrimination asks whether the ranking holds; calibration asks whether the predicted        */
/*   level is right. A model can rank correctly and still under-predict badly                     */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Calibration_Check;

    PROC RANK DATA=MODEL.ValidScored OUT=WORK.ValidDecile GROUPS=10;
        VAR P_1;
        RANKS ScoreDecile;
    RUN;

    PROC SQL;
        CREATE TABLE REPORT.CalibrationByBand AS
        SELECT ScoreDecile                LABEL="Score decile",
               count(*)      AS Loans     FORMAT=COMMA12. LABEL="Loans",
               mean(P_1)     AS Predicted FORMAT=PERCENT8.2 LABEL="Predicted default rate",
               mean(DefaultFlag) AS Actual FORMAT=PERCENT8.2 LABEL="Actual default rate"
        FROM WORK.ValidDecile
        GROUP BY ScoreDecile;

        TITLE "Calibration by Score Decile - Out-of-Time Validation";
        SELECT * FROM REPORT.CalibrationByBand;

        CREATE TABLE REPORT.CalibrationByYear AS
        SELECT OrigYear                   LABEL="Origination year",
               count(*)      AS Loans     FORMAT=COMMA12. LABEL="Loans",
               mean(P_1)     AS Predicted FORMAT=PERCENT8.2 LABEL="Predicted default rate",
               mean(DefaultFlag) AS Actual FORMAT=PERCENT8.2 LABEL="Actual default rate"
        FROM MODEL.ValidScored
        GROUP BY OrigYear;

        TITLE "Calibration by Origination Year - Out-of-Time Validation";
        SELECT * FROM REPORT.CalibrationByYear;
    QUIT;

    TITLE;

%MEND Calibration_Check;


/**************************************************************************************************/
/*                                                                                                */
/*   Psi_Stability macro measures how far the validation population has drifted from the          */
/*   training population                                                                          */
/*   PSI = sum over bins of (percent new - percent old) x ln(percent new / percent old)           */
/*   Under 0.10 stable, 0.10 to 0.25 minor shift, over 0.25 significant                           */
/*   What is monitored is the model score, not a single predictor: the training scores are        */
/*   cut into ten bands, those cut points are written into a format, and the format is            */
/*   applied unchanged to validation - so validation is never re-ranked                           */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Psi_Stability;

    /*   Score the training sample so both samples carry a comparable predicted probability   */
    PROC LOGISTIC INMODEL=MODEL.PdModel;
        SCORE DATA=MODEL.TrainWoe OUT=WORK.TrainScored;
    RUN;

    /*   Ten equal training bands and the predicted probability closing each one   */
    PROC RANK DATA=WORK.TrainScored OUT=WORK.TrainBand GROUPS=10;
        VAR P_1;
        RANKS Band;
    RUN;

    PROC MEANS DATA=WORK.TrainBand NOPRINT NWAY;
        CLASS Band;
        VAR P_1;
        OUTPUT OUT=WORK.BandCuts (DROP=_TYPE_ _FREQ_) N=NTrain MIN=CutLow MAX=CutHigh;
    RUN;

    /*   Turn the training cut points into a format   */
    DATA WORK.BandFmt;
        SET WORK.BandCuts END=Last;
        LENGTH FmtName $8 Label $8;
        RETAIN FmtName "PsiBand" Type "N";
        Start = CutLow;
        End   = CutHigh;
        Label = PUT(Band, 2.);
        IF _N_  = 1    THEN HLo = "L";
        IF Last        THEN HLo = "H";
        KEEP FmtName Type Start End Label HLo;
    RUN;

    PROC FORMAT CNTLIN=WORK.BandFmt;
    RUN;

    /*   Apply the training bands to validation   */
    DATA WORK.ValidBand;
        SET MODEL.ValidScored (KEEP=P_1);
        Band = INPUT(PUT(P_1, PsiBand.), 2.);
    RUN;

    PROC MEANS DATA=WORK.ValidBand NOPRINT NWAY;
        CLASS Band;
        VAR P_1;
        OUTPUT OUT=WORK.ValidCounts (DROP=_TYPE_ _FREQ_) N=NValid;
    RUN;

    /*   Compare the two distributions band by band   */
    DATA REPORT.Psi;
        MERGE WORK.BandCuts (KEEP=Band NTrain CutHigh)
              WORK.ValidCounts;
        BY Band;
        IF NValid = . THEN NValid = 0;
    RUN;

    PROC SQL NOPRINT;
        SELECT sum(NTrain), sum(NValid)
          INTO :SumTrain trimmed, :SumValid trimmed
        FROM REPORT.Psi;
    QUIT;

    DATA REPORT.Psi;
        SET REPORT.Psi END=Last;
        RETAIN PsiTotal 0;

        PctTrain = NTrain / &SumTrain;
        PctValid = NValid / &SumValid;

        IF PctTrain > 0 AND PctValid > 0 THEN
            PsiPart = (PctValid - PctTrain) * log(PctValid / PctTrain);
        ELSE PsiPart = 0;

        PsiTotal + PsiPart;
        IF Last THEN Psi = PsiTotal;

        FORMAT NTrain NValid COMMA12. PctTrain PctValid PERCENT8.2
               CutHigh PERCENT8.3 PsiPart Psi 8.4;
        LABEL Band     = "Score band"
              CutHigh  = "Predicted default at band top"
              NTrain   = "Training loans"
              NValid   = "Validation loans"
              PctTrain = "Percent training"
              PctValid = "Percent validation"
              PsiPart  = "PSI contribution"
              Psi      = "Population Stability Index";
        DROP PsiTotal;
    RUN;

    PROC PRINT DATA=REPORT.Psi NOOBS LABEL;
        TITLE "Population Stability Index - Training versus Out-of-Time Validation";
        VAR Band CutHigh NTrain NValid PctTrain PctValid PsiPart Psi;
    RUN;

    TITLE;

%MEND Psi_Stability;

%Points_Scorecard;

%Score_Validation;

%Calibration_Check;

%Psi_Stability;

/**************************************************************************************************/
/**************************************************************************************************/
/**************************************************************************************************/ 

/**************************************************************************************************/
/*                                                                                                */
/*   Generate_Pdf macro produces the model development report as a PDF                   */
/*   Cover, introduction, source data, methodology, portfolio, risk profile, discrimination,      */
/*   calibration, stability, glossary, and the ETL processing record as an appendix               */
/*   Last step, run %Generate_Pdf; after every modeling stage is complete                */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Generate_Pdf;

    PROC TEMPLATE;
        DEFINE STYLE ScorecardStyle;
            PARENT = Styles.Pearl;
            CLASS Fonts /
                'TitleFont'    = ("Helvetica", 13PT, BOLD)
                'HeadingFont'  = ("Helvetica", 10PT, BOLD)
                'DocFont'      = ("Helvetica", 9PT);
            CLASS Header       / BACKGROUNDCOLOR=CX1F4E79 COLOR=WHITE;
            CLASS SystemTitle  / COLOR=CX1F4E79 FONTSIZE=13PT;
            CLASS SystemTitle2 / COLOR=CX1F4E79 FONTSIZE=12PT FONTWEIGHT=MEDIUM;
        END;
    RUN;

    OPTIONS NODATE NONUMBER ORIENTATION=PORTRAIT
            TOPMARGIN=1IN BOTTOMMARGIN=1IN LEFTMARGIN=1IN RIGHTMARGIN=1IN;
    ODS _ALL_ CLOSE;
    ODS GRAPHICS ON / WIDTH=6.4IN HEIGHT=2.6IN OUTPUTFMT=PNG;
    ODS ESCAPECHAR='^';

    /*   CONTENTS=NO so the cover is page 1 - the contents page is written by hand below,    */
    /*   and the PDF bookmark panel still navigates the sections                              */
    ODS PDF FILE="&root/CreditRiskScorecard_Report.pdf"
            STYLE=ScorecardStyle STARTPAGE=NO CONTENTS=NO;

    /*   Cover   */
    PROC ODSTEXT;
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
    RUN;
    PROC ODSTEXT;
        P "Credit Risk Scorecard"
          / STYLE=[FONTSIZE=22PT FONTWEIGHT=BOLD COLOR=CX1F4E79 JUST=CENTER];
        P "Out-of-Time Validation Through the 2008 Crisis"
          / STYLE=[FONTSIZE=13PT FONTWEIGHT=BOLD COLOR=CX1F4E79 JUST=CENTER];
        P "Trained on 2000-2005 loans"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P "Tested on 2006-2007 loans"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "Fannie Mae Single-Family Loan Performance Data"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P "Anne M. Prihoda"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "What this report covers"
          / STYLE=[FONTSIZE=12PT FONTWEIGHT=BOLD COLOR=CX1F4E79];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Builds a loan-level credit risk scorecard on 2000 to 2005 mortgage originations using predictor binning, Weight of Evidence, logistic regression, and points scaling"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Validates the scorecard out-of-time on 2006 to 2007 originations, which seasoned through the housing crisis"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Weight of Evidence (WOE) converts each predictor onto a common risk scale by comparing, within each range of values, the share of loans that repaid against the share that defaulted. Information Value (IV) sums that separation across all ranges into a single number measuring how much a predictor is worth"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Discrimination is measured by the Kolmogorov-Smirnov statistic (KS), the widest gap between defaults captured and non-defaults captured, and by the ROC curve and the area beneath it (AUC)"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Calibration asks whether the predicted level of default is right, comparing predicted against actual by score band and by origination year. A model can rank loans correctly and still badly understate how many will default"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Population stability asks whether the applicants being scored still resemble those the model was built on, measured by the Population Stability Index (PSI), the standard early warning in model monitoring"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Data prepared by the ETL pipeline: 1,178,508,035 monthly records across 48 quarterly files, reconciled to Fannie Mae published statistical summaries"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    ODS PDF STARTPAGE=NOW;

    /*   Contents - written by hand so the cover can be page 1                                */
    /*   Every narrative paragraph in this report is written through PROC ODSTEXT at 10PT,     */
    /*   so the contents, the cover and the section commentary all render at the same size     */
    PROC ODSTEXT;
        P "Contents"
          / STYLE=[FONTSIZE=12PT FONTWEIGHT=BOLD COLOR=CX1F4E79];
    RUN;
    PROC ODSTEXT;
        P "1.  Portfolio Composition and Observed Default"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "2.  Credit Score Risk Profile"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "3.  The Scorecard"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "4.  Model Discrimination"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "5.  Calibration - Predicted versus Actual"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "6.  Population Stability"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "Appendix.  Data Processing Record"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P " " / STYLE=[FONTSIZE=5PT];
    RUN;

    /*   Section 1 - portfolio, on the same page as the contents   */
    ODS PROCLABEL "1. Portfolio and Observed Default";
    TITLE1 "1.  Portfolio Composition and Observed Default";
    PROC ODSTEXT;
        P "^{unicode 2022}  19.1 million prime, fully documented, fixed-rate mortgages acquired by Fannie Mae between 2000 and 2007"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Loan counts and default rates reconcile to Fannie Mae published summaries within a few basis points on every vintage"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Default rates hold between 1.2 and 1.6 percent for loans made from 2000 through 2003"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  They then climb steeply: 3.2 percent in 2004, 6.0 percent in 2005, and 8 to 9 percent in 2006 and 2007"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  That is a sevenfold deterioration inside the safest segment of the mortgage market"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  It happened with no comparable movement in the characteristics lenders were underwriting on"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    PROC SQL;
        SELECT OrigYear          LABEL="Origination year",
               count(*)           AS Loans    FORMAT=COMMA12. LABEL="Loans",
               sum(DefaultFlag)   AS Defaults FORMAT=COMMA12. LABEL="Defaults",
               mean(DefaultFlag)  AS DefRate  FORMAT=PERCENT8.2 LABEL="Default rate"
        FROM MODEL.ModelBase
        GROUP BY OrigYear;
    QUIT;

    /*   Summarize before plotting - SGPLOT cannot render 19 million rows directly   */
    PROC MEANS DATA=MODEL.ModelBase NOPRINT NWAY;
        CLASS OrigYear;
        VAR DefaultFlag;
        OUTPUT OUT=WORK._YearRate (DROP=_TYPE_ _FREQ_) MEAN=DefRate;
    RUN;

    TITLE2 "Observed default rate by origination year";
    PROC SGPLOT DATA=WORK._YearRate;
        VBAR OrigYear / RESPONSE=DefRate FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Default rate" VALUESFORMAT=PERCENT8.1 GRID;
        XAXIS LABEL="Origination year";
    RUN;

    /*   Section 2 - risk profile   */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "2. Credit Score Risk Profile";
    TITLE1 "2.  Credit Score Risk Profile";
    TITLE2 "Weight of Evidence by fine bin, training sample";
    PROC ODSTEXT;
        P "^{unicode 2022}  Each bar is one twentieth of the training population, weakest credit scores on the left, strongest on the right"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Weight of Evidence compares a bin's share of loans that repaid with its share that defaulted"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Bars below zero hold more than their share of defaults; bars above zero hold fewer"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The climb from minus 0.90 to plus 1.38 is steady and almost perfectly ordered"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Information Value of 0.53 on 16.8 million loans, the strongest characteristic tested"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    PROC SGPLOT DATA=SCORE.FicoBins;
        VBAR RFico / RESPONSE=Woe FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Weight of Evidence" GRID;
        XAXIS LABEL="Credit score bin, 0 is highest risk";
    RUN;

    PROC PRINT DATA=SCORE.FicoBins NOOBS LABEL;
        VAR RFico RawMin RawMax NLoans NBad Woe;
        LABEL RFico="Bin" RawMin="From" RawMax="To" NLoans="Loans"
              NBad="Defaults" Woe="WOE";
    RUN;

    /*   Section 3 - the scorecard   */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "3. The Scorecard";
    TITLE1 "3.  The Scorecard";
    TITLE2 "Points by characteristic and class";
    PROC ODSTEXT;
        P "^{unicode 2022}  Add the points for each of the three characteristics to obtain the loan score"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Higher points mean lower risk"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  600 points corresponds to 50 to 1 odds of repayment"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Every 20 additional points doubles those odds"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC PRINT DATA=SCORE.Points NOOBS LABEL;
        VAR Characteristic Bin Woe Points;
    RUN;

    /*   Section 4 - discrimination   */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "4. Discrimination";
    TITLE1 "4.  Model Discrimination";
    TITLE2 "Out-of-time validation";
    PROC ODSTEXT;
        P "^{unicode 2022}  Discrimination asks whether the model puts riskier loans ahead of safer ones"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  KS is the widest gap between defaults captured and non-defaults captured, working from worst score to best"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The ROC curve shows the same separation: The further it bows above the diagonal, the better the ranking"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The model was fitted on 2000 to 2005 loans and applied untouched to 2006 and 2007 loans it had never seen"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  KS falls only from 37.3 to 32.1, and area under the curve from 0.746 to 0.716"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The ranking held: Riskier loans still scored worse and safer loans still scored better, on loans originated after the training period"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Ranking correctly is not the same as predicting correctly: Section 5 shows the predicted level of default was far too low"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    PROC PRINT DATA=REPORT.KsSummary NOOBS LABEL;
    RUN;

    PROC SGPLOT DATA=REPORT.RocValid ASPECT=1;
        TITLE2 "ROC curve - validation sample";
        SERIES X=_1MSPEC_ Y=_SENSIT_ / LINEATTRS=(COLOR=CX1F4E79 THICKNESS=2);
        LINEPARM X=0 Y=0 SLOPE=1 / LINEATTRS=(PATTERN=SHORTDASH COLOR=GRAY);
        XAXIS LABEL="False positive rate" GRID;
        YAXIS LABEL="True positive rate" GRID;
    RUN;

    /*   Section 5 - calibration   */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "5. Calibration";
    TITLE1 "5.  Calibration - Predicted versus Actual";
    TITLE2 "By score decile";
    PROC ODSTEXT;
        P "^{unicode 2022}  Discrimination asks whether the ordering is right; Calibration asks whether the predicted level is right"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  A model can rank every loan correctly and still be badly wrong about how many will default"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Ordering is flawless: Predicted default rises from 0.19 to 6.28 percent across deciles, actual from 0.54 to 19.64 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Every decile is in the right place, and every decile is understated by a factor of three to four"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  2006 originations: Predicted default rate 2.10 percent, actual default rate 8.17 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  2007 originations: Predicted default rate 2.26 percent, actual default rate 8.94 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The model barely separated the two vintages because the applicants barely differed"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The difference was in the environment those loans matured into, which no origination characteristic can express"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    PROC PRINT DATA=REPORT.CalibrationByBand NOOBS LABEL;
    RUN;

    TITLE2 "By origination year";
    PROC PRINT DATA=REPORT.CalibrationByYear NOOBS LABEL;
    RUN;

    /*   Section 6 - stability   */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "6. Population Stability";
    TITLE1 "6.  Population Stability";
    TITLE2 "Training versus validation score distribution";
    PROC ODSTEXT;
        P "^{unicode 2022}  PSI compares the score distribution of the new population against the population the model was built on"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Below 0.10 is stable and requires no action; 0.10 to 0.25 is a minor shift; Above 0.25 calls for investigation or a rebuild"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The index comes to 0.031, comfortably inside the stable range"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Applicants arriving in 2006 and 2007 looked very much like those the model was trained on"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  A monitoring report built on this measure would have raised no alarm while the book defaulted at four times the predicted rate"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The scorecard method worked: It ranked risk correctly and its inputs stayed stable"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  What failed was the assumption that the relationship between borrower characteristics and default holds steady over time"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Population monitoring cannot detect that failure because it watches applicants rather than outcomes"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Actual-versus-predicted tracking, shown in Section 5, is what would have caught it, within months of the 2006 vintage seasoning"
          / STYLE=[FONTSIZE=10PT];
    RUN;
    PROC PRINT DATA=REPORT.Psi NOOBS LABEL;
        VAR Band CutHigh NTrain NValid PctTrain PctValid PsiPart Psi;
    RUN;

    /*   Appendix - the ETL processing record, reproduced exactly as it appears in the        */
    /*   ETL Pipeline report so readers can match the two projects                            */
    ODS PDF STARTPAGE=NOW;
    ODS PROCLABEL "Appendix. Data Processing Record";
    TITLE1 "Appendix.  Data Processing Record";
    TITLE2 "ETL Pipeline Processing Record";

    /*   Narrower margins and a smaller font so all eight columns fit one page width,        */
    /*   matching the layout of the ETL Pipeline report                                      */
    OPTIONS LEFTMARGIN=0.5IN RIGHTMARGIN=0.5IN;

    PROC PRINT DATA=FNMAE.RunLog NOOBS LABEL
               STYLE(HEADER)=[FONTSIZE=7PT]
               STYLE(DATA)  =[FONTSIZE=7PT];
    RUN;

    OPTIONS LEFTMARGIN=1IN RIGHTMARGIN=1IN;

    TITLE1 "ETL Pipeline: Grand Totals";
    PROC SQL;
        SELECT count(*)                        LABEL="Data sets processed",
               sum(RawRows)                    LABEL="Total monthly records"      FORMAT=COMMA18.,
               sum(LoanRows)                   LABEL="Total loans"               FORMAT=COMMA14.,
               sum(Defaults)                    LABEL="Total defaults"            FORMAT=COMMA12.,
               sum(ProcessTime)                LABEL="Total SAS processing time"  FORMAT=TIME12.,
               sum(RawRows) / sum(ProcessTime) LABEL="Records per second"         FORMAT=COMMA12.
        FROM FNMAE.RunLog;
    QUIT;

    TITLE2 "Monthly records read by acquisition quarter";
    PROC SGPLOT DATA=FNMAE.RunLog;
        VBAR Quarter / RESPONSE=RawRows STAT=SUM FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Monthly records" GRID;
        XAXIS LABEL="Acquisition quarter" FITPOLICY=THIN;
    RUN;

    TITLE;
    ODS PDF CLOSE;
    ODS GRAPHICS OFF;

%MEND Generate_Pdf;

%Generate_Pdf;


/**************************************************************************************************/
/*                                                                                                */
/*   Generate_WebReport macro produces the same report as one self-contained HTML page            */
/*   Charts embed as inline SVG so index.html needs no supporting files                           */
/*   Download index.html, commit it to the docs folder, and publish through GitHub Pages          */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Generate_WebReport;

    /*   The same report as one self-contained HTML page - same style, same cover, same       */
    /*   commentary and the same sections as the PDF                                          */
    PROC TEMPLATE;
        DEFINE STYLE ScorecardWeb;
            PARENT = Styles.Pearl;
            CLASS Fonts /
                'TitleFont'    = ("Helvetica", 13PT, BOLD)
                'HeadingFont'  = ("Helvetica", 10PT, BOLD)
                'DocFont'      = ("Helvetica", 10PT);
            CLASS Header       / BACKGROUNDCOLOR=CX1F4E79 COLOR=WHITE;
            CLASS SystemTitle  / COLOR=CX1F4E79 FONTSIZE=13PT;
            CLASS SystemTitle2 / COLOR=CX1F4E79 FONTSIZE=12PT FONTWEIGHT=MEDIUM;
        END;
    RUN;

    OPTIONS NODATE NONUMBER;
    ODS _ALL_ CLOSE;
    ODS GRAPHICS ON / WIDTH=6.4IN HEIGHT=2.6IN OUTPUTFMT=SVG;
    ODS ESCAPECHAR='^';

    ODS HTML5 FILE="&root/index.html" STYLE=ScorecardWeb
              OPTIONS(SVG_MODE="INLINE") GTITLE GFOOTNOTE;

    /*   Cover   */
    PROC ODSTEXT;
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
    RUN;

    PROC ODSTEXT;
        P "Credit Risk Scorecard"
          / STYLE=[FONTSIZE=22PT FONTWEIGHT=BOLD COLOR=CX1F4E79 JUST=CENTER];
        P "Out-of-Time Validation Through the 2008 Crisis"
          / STYLE=[FONTSIZE=13PT FONTWEIGHT=BOLD COLOR=CX1F4E79 JUST=CENTER];
        P "Trained on 2000-2005 loans"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P "Tested on 2006-2007 loans"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "Fannie Mae Single-Family Loan Performance Data"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P "Anne M. Prihoda"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79 JUST=CENTER];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "What this report covers"
          / STYLE=[FONTSIZE=12PT FONTWEIGHT=BOLD COLOR=CX1F4E79];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Builds a loan-level credit risk scorecard on 2000 to 2005 mortgage originations using predictor binning, Weight of Evidence, logistic regression, and points scaling"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Validates the scorecard out-of-time on 2006 to 2007 originations, which seasoned through the housing crisis"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Weight of Evidence (WOE) converts each predictor onto a common risk scale by comparing, within each range of values, the share of loans that repaid against the share that defaulted. Information Value (IV) sums that separation across all ranges into a single number measuring how much a predictor is worth"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Discrimination is measured by the Kolmogorov-Smirnov statistic (KS), the widest gap between defaults captured and non-defaults captured, and by the ROC curve and the area beneath it (AUC)"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Calibration asks whether the predicted level of default is right, comparing predicted against actual by score band and by origination year. A model can rank loans correctly and still badly understate how many will default"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Population stability asks whether the applicants being scored still resemble those the model was built on, measured by the Population Stability Index (PSI), the standard early warning in model monitoring"
          / STYLE=[FONTSIZE=10PT];
        P " " / STYLE=[FONTSIZE=5PT];
        P "^{unicode 2022}  Data prepared by the ETL pipeline: 1,178,508,035 monthly records across 48 quarterly files, reconciled to Fannie Mae published statistical summaries"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    /*   Contents   */
    PROC ODSTEXT;
        P "Contents"
          / STYLE=[FONTSIZE=12PT FONTWEIGHT=BOLD COLOR=CX1F4E79];
        P " " / STYLE=[FONTSIZE=5PT];
        P "1.  Portfolio Composition and Observed Default"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "2.  Credit Score Risk Profile"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "3.  The Scorecard"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "4.  Model Discrimination"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "5.  Calibration - Predicted versus Actual"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "6.  Population Stability"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P "Appendix.  Data Processing Record"
          / STYLE=[FONTSIZE=12PT COLOR=CX1F4E79];
        P " " / STYLE=[FONTSIZE=5PT];
    RUN;

    /*   Section 1 - portfolio   */
    TITLE1 "1.  Portfolio Composition and Observed Default";
    TITLE2;
    PROC ODSTEXT;
        P "^{unicode 2022}  19.1 million prime, fully documented, fixed-rate mortgages acquired by Fannie Mae between 2000 and 2007"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Loan counts and default rates reconcile to Fannie Mae published summaries within a few basis points on every vintage"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Default rates hold between 1.2 and 1.6 percent for loans made from 2000 through 2003"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  They then climb steeply: 3.2 percent in 2004, 6.0 percent in 2005, and 8 to 9 percent in 2006 and 2007"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  That is a sevenfold deterioration inside the safest segment of the mortgage market"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  It happened with no comparable movement in the characteristics lenders were underwriting on"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC SQL;
        SELECT OrigYear          LABEL="Origination year",
               count(*)           AS Loans    FORMAT=COMMA12. LABEL="Loans",
               sum(DefaultFlag)   AS Defaults FORMAT=COMMA12. LABEL="Defaults",
               mean(DefaultFlag)  AS DefRate  FORMAT=PERCENT8.2 LABEL="Default rate"
        FROM MODEL.ModelBase
        GROUP BY OrigYear;
    QUIT;

    /*   Summarize before plotting - SGPLOT cannot render 19 million rows directly   */
    PROC MEANS DATA=MODEL.ModelBase NOPRINT NWAY;
        CLASS OrigYear;
        VAR DefaultFlag;
        OUTPUT OUT=WORK._YearRate (DROP=_TYPE_ _FREQ_) MEAN=DefRate;
    RUN;

    TITLE2 "Observed default rate by origination year";
    PROC SGPLOT DATA=WORK._YearRate;
        VBAR OrigYear / RESPONSE=DefRate FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Default rate" VALUESFORMAT=PERCENT8.1 GRID;
        XAXIS LABEL="Origination year";
    RUN;

    /*   Section 2 - risk profile   */
    TITLE1 "2.  Credit Score Risk Profile";
    TITLE2 "Weight of Evidence by fine bin, training sample";
    PROC ODSTEXT;
        P "^{unicode 2022}  Each bar is one twentieth of the training population, weakest credit scores on the left, strongest on the right"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Weight of Evidence compares a bin's share of loans that repaid with its share that defaulted"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Bars below zero hold more than their share of defaults; bars above zero hold fewer"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The climb from minus 0.90 to plus 1.38 is steady and almost perfectly ordered"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Information Value of 0.53 on 16.8 million loans, the strongest characteristic tested"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC SGPLOT DATA=SCORE.FicoBins;
        VBAR RFico / RESPONSE=Woe FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Weight of Evidence" GRID;
        XAXIS LABEL="Credit score bin, 0 is highest risk";
    RUN;

    PROC PRINT DATA=SCORE.FicoBins NOOBS LABEL;
        VAR RFico RawMin RawMax NLoans NBad Woe;
        LABEL RFico="Bin" RawMin="From" RawMax="To" NLoans="Loans"
              NBad="Defaults" Woe="WOE";
    RUN;

    /*   Section 3 - the scorecard   */
    TITLE1 "3.  The Scorecard";
    TITLE2 "Points by characteristic and class";
    PROC ODSTEXT;
        P "^{unicode 2022}  Add the points for each of the three characteristics to obtain the loan score"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Higher points mean lower risk"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  600 points corresponds to 50 to 1 odds of repayment"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Every 20 additional points doubles those odds"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC PRINT DATA=SCORE.Points NOOBS LABEL;
        VAR Characteristic Bin Woe Points;
    RUN;

    /*   Section 4 - discrimination   */
    TITLE1 "4.  Model Discrimination";
    TITLE2 "Out-of-time validation";
    PROC ODSTEXT;
        P "^{unicode 2022}  Discrimination asks whether the model puts riskier loans ahead of safer ones"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  KS is the widest gap between defaults captured and non-defaults captured, working from worst score to best"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The ROC curve shows the same separation: The further it bows above the diagonal, the better the ranking"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The model was fitted on 2000 to 2005 loans and applied untouched to 2006 and 2007 loans it had never seen"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  KS falls only from 37.3 to 32.1, and area under the curve from 0.746 to 0.716"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The ranking held: Riskier loans still scored worse and safer loans still scored better, on loans originated after the training period"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Ranking correctly is not the same as predicting correctly: Section 5 shows the predicted level of default was far too low"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC PRINT DATA=REPORT.KsSummary NOOBS LABEL;
    RUN;

    TITLE2 "ROC curve - validation sample";
    PROC SGPLOT DATA=REPORT.RocValid ASPECT=1;
        SERIES X=_1MSPEC_ Y=_SENSIT_ / LINEATTRS=(COLOR=CX1F4E79 THICKNESS=2);
        LINEPARM X=0 Y=0 SLOPE=1 / LINEATTRS=(PATTERN=SHORTDASH COLOR=GRAY);
        XAXIS LABEL="False positive rate" GRID;
        YAXIS LABEL="True positive rate" GRID;
    RUN;

    /*   Section 5 - calibration   */
    TITLE1 "5.  Calibration - Predicted versus Actual";
    TITLE2 "By score decile";
    PROC ODSTEXT;
        P "^{unicode 2022}  Discrimination asks whether the ordering is right; Calibration asks whether the predicted level is right"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  A model can rank every loan correctly and still be badly wrong about how many will default"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Ordering is flawless: Predicted default rises from 0.19 to 6.28 percent across deciles, actual from 0.54 to 19.64 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Every decile is in the right place, and every decile is understated by a factor of three to four"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  2006 originations: Predicted default rate 2.10 percent, actual default rate 8.17 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  2007 originations: Predicted default rate 2.26 percent, actual default rate 8.94 percent"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The model barely separated the two vintages because the applicants barely differed"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The difference was in the environment those loans matured into, which no origination characteristic can express"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC PRINT DATA=REPORT.CalibrationByBand NOOBS LABEL;
    RUN;

    TITLE2 "By origination year";
    PROC PRINT DATA=REPORT.CalibrationByYear NOOBS LABEL;
    RUN;

    /*   Section 6 - stability   */
    TITLE1 "6.  Population Stability";
    TITLE2 "Training versus validation score distribution";
    PROC ODSTEXT;
        P "^{unicode 2022}  PSI compares the score distribution of the new population against the population the model was built on"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Below 0.10 is stable and requires no action; 0.10 to 0.25 is a minor shift; Above 0.25 calls for investigation or a rebuild"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The index comes to 0.031, comfortably inside the stable range"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Applicants arriving in 2006 and 2007 looked very much like those the model was trained on"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  A monitoring report built on this measure would have raised no alarm while the book defaulted at four times the predicted rate"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  The scorecard method worked: It ranked risk correctly and its inputs stayed stable"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  What failed was the assumption that the relationship between borrower characteristics and default holds steady over time"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Population monitoring cannot detect that failure because it watches applicants rather than outcomes"
          / STYLE=[FONTSIZE=10PT];
        P "^{unicode 2022}  Actual-versus-predicted tracking, shown in Section 5, is what would have caught it, within months of the 2006 vintage seasoning"
          / STYLE=[FONTSIZE=10PT];
    RUN;

    PROC PRINT DATA=REPORT.Psi NOOBS LABEL;
        VAR Band CutHigh NTrain NValid PctTrain PctValid PsiPart Psi;
    RUN;

    /*   Appendix - the ETL processing record, matching the ETL Pipeline report   */
    TITLE1 "Appendix.  Data Processing Record";
    TITLE2 "ETL Pipeline Processing Record";
    PROC PRINT DATA=FNMAE.RunLog NOOBS LABEL
               STYLE(HEADER)=[FONTSIZE=8PT]
               STYLE(DATA)  =[FONTSIZE=8PT];
    RUN;

    TITLE1 "ETL Pipeline: Grand Totals";
    PROC SQL;
        SELECT count(*)                        LABEL="Data sets processed",
               sum(RawRows)                    LABEL="Total monthly records"      FORMAT=COMMA18.,
               sum(LoanRows)                   LABEL="Total loans"               FORMAT=COMMA14.,
               sum(Defaults)                    LABEL="Total defaults"            FORMAT=COMMA12.,
               sum(ProcessTime)                LABEL="Total SAS processing time"  FORMAT=TIME12.,
               sum(RawRows) / sum(ProcessTime) LABEL="Records per second"         FORMAT=COMMA12.
        FROM FNMAE.RunLog;
    QUIT;

    TITLE2 "Monthly records read by acquisition quarter";
    PROC SGPLOT DATA=FNMAE.RunLog;
        VBAR Quarter / RESPONSE=RawRows STAT=SUM FILLATTRS=(COLOR=CX1F4E79);
        YAXIS LABEL="Monthly records" GRID;
        XAXIS LABEL="Acquisition quarter" FITPOLICY=THIN;
    RUN;

    TITLE;
    ODS HTML5 CLOSE;
    ODS GRAPHICS OFF;

%MEND Generate_WebReport;

%Generate_WebReport;

/**************************************************************************************************/
/**************************************************************************************************/
/**************************************************************************************************/ 

/**************************************************************************************************/
/*                                                                                                */
/*   Optional_Checks_Code macro compartmentalizes various checks that can be run at any time      */
/*   Check #1 - Model predictors: ranges and missing counts in the model base                     */
/*   Check #2 - Storage by library and dataset: file sizes against the 5 GB limit                 */
/*   Check #3 - Row counts: every permanent table in the project libraries                        */
/*   Check #4 - WORK reset: empties the WORK scratch library. Starred - un-star only after        */
/*              a failed run                                                                      */
/*   Run any check at any time to validate successful code execution                              */
/*                                                                                                */
/**************************************************************************************************/

%MACRO Optional_Checks_Code;

    /*   Check #1 - Model predictors: ranges and missing counts   */
    PROC MEANS DATA=MODEL.ModelBase n nmiss min max mean MAXDEC=1;
        TITLE "Check 1 - Model Predictors: Ranges and Missing Counts";
        VAR FICO LTV CLTV DTI OrigUPB NoteRate;
    RUN;

    /*   Check #2 - Storage by library and dataset, largest first   */
    PROC SQL;
        TITLE "Check 2 - Storage by Library and Dataset";
        SELECT Libname  LABEL="Library",
               Memname  LABEL="Dataset",
               Filesize FORMAT=SIZEKMG12.1 LABEL="Size of file",
               Nobs     FORMAT=COMMA14.    LABEL="Rows"
        FROM DICTIONARY.Tables
        WHERE Libname in ('FNMAE', 'MODEL', 'SCORE', 'REPORT')
        ORDER BY Filesize DESC;
    QUIT;

    /*   Check #3 - Row counts for every permanent table   */
    PROC SQL;
        TITLE "Check 3 - Row Counts by Table";
        SELECT Libname   LABEL="Library",
               Memname   LABEL="Dataset",
               Nobs      FORMAT=COMMA14. LABEL="Rows"
        FROM DICTIONARY.Tables
        WHERE Libname in ('FNMAE', 'MODEL', 'SCORE', 'REPORT')
        ORDER BY Libname, Memname;
    QUIT;

    TITLE;

    /*   Check #4 - WORK reset: empties the WORK library. Un-star only after a failed run   */
    *PROC DATASETS LIBRARY=WORK KILL NOLIST;
    *QUIT;

%MEND Optional_Checks_Code;

%Optional_Checks_Code;

/**************************************************************************************************/
/**************************************************************************************************/
/**************************************************************************************************/

/*   Release the session log - run once after all modeling is complete, so the log file           */
/*   is closed and can be downloaded. Un-star, run, then restore the asterisks                    */
*PROC PRINTTO;
*RUN;