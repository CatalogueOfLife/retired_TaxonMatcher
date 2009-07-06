#!/usr/local/bin/perl -w

$programName=  "Taxon Matcher";
$programVersion=  "1.03, 23 February 2009";

# Compare taxa in two editions of the Catalogue of Life Annual Checklist
# and allocate LSIDs to every taxon (concept) which does not have an LSID
# Richard J. White,
#  7 October  2008  initial version
# 21 December 2008  additional SQL commands
# 22 December 2008  work in Reading: two simultaneous database connections 
# 23 December 2008  v. 0.12  program update process
#  5 January  2009  accepted names included in comparison of taxa
#  6 January  2009  switches for users and with both ODBC and native MySQL drivers
#  9 January  2009  synonymy included in comparison
# 12 January  2009  (trying to get) distribution and other data included in comparison
# 14 January  2009  v. 0.23, LSID values generated
# 15 January  2009  v. 0.24, LSID values inserted into new CoL database
# 16 January  2009  v. 0.30, to Reading for testing, main loop for better user control
# 18 January  2009  test menus added
# 21 January  2009  first tests included
# 27 January  2009  further tests added
# 29 January  2009  logging actions and results
#  3 February 2009  
#  7 February 2009  read configuration file for default settings
# 10 February 2009  higher taxa added
# 11 February 2009  more robust strategy to allocate LSIDs to all taxa before matching
# 12 February 2009  improved choice of index type for much faster comparison
# 15 February 2009  fixed various bugs causing duplicated LSIDs
# 16 February 2009  import subset of taxon names for testing
# 17 February 2009  fix to provide a default column value required by some DBMS systems
# 18 February 2009  v. 1.00, additional LSID matching tests
# 19 February 2009  v. 1.01, tried and failed to fix duplicated families bug
# 23 February 2009  detect and remove leading, trailing and duplicated spaces

print "\n$programName (version $programVersion)\n\n";

use DBI;
use Switch;
use Time::HiRes qw(time);  # elapsed time measurement function
use Term::ReadKey;

# Read configuration file to set default values
# ---------------------------------------------
# (could be extended to read more than one config file, e.g. system, user, ...)

$configFileName= "TaxonMatcher.config";

for $file ($configFileName)
{ $return = do $file;
  if (defined $return)
  { print "Configuration file \"$file\" successfully read\n";
  }
  else
  { warn "Couldn't parse $file: $@" if $@;
    warn "Couldn't read $file: $!" if $!;
  }
}

# Start logging, if required
$logging= $logFileName ne "";
&beginLogFile($logFileName) if $logging;

# Set the special variable $| to "flush" screen output (to make it
# appear immediately, needed when waiting for user response to a prompt)
#select STDOUT;  $|= 1;

print "Configured for $user ($userName), "
    . "running on $OS using the $driver driver.\n"
    . "If this is not correct, the user name or "
    . "default values may need changing.\n\n";

@lsidsPresent= (0, 0);
$prefixLSID= "urn:lsid:catalogueoflife.org:taxon:";

if ($driver eq "MySQL")
{ # Import the MySQL driver module to use MySQL directly (doesn't work with Perl 5.10!)
  $drh=DBI->install_driver('mysql') || warn "no Driver\n";
}
elsif ($driver eq "ODBC")
{ # Import the MySQL driver module to use MySQL via ODBC
  # (no module needs to be imported?)
}

# Show the current option settings, so the user can choose to change them
showOptions();     
connectDbs();
setLimitClauses();

# Start of the main loop
# ======================

LOOP:
for (;;)  # infinite loop
{ # Display the main menu
  print "\n---Main menu----------------------------------------------------------------\n"
      . "H:  show Help text		C:  Compare AC editions\n"
      . "O:  change Options		S:  comparison Statistics and tests\n"
      . "E:  Empty comparison database	A:  Add LSIDs to AC edition\n"
      . "T:  Test AC edition		L:  test LSIDs in AC edition\n"
      . "I:  Import AC edition		R:  Remove LSIDs from AC edition\n"
      . "Q:  Quit program\n";
  # Execute the user's selected alternative
  switch (getKey())
  { case "H"	{ showHelp() }
    case "O"	{ print "change Options\n";  
                  changeOptions() 
                }
    case "E"	{ emptyCTL() }
    case "T"	{ testAC() }
    case "I"	{ importAC() }
    case "C"	{ compareEditions() }
    case "S"	{ showStatistics() }
    case "A"	{ addLSIDs() }
    case "L"	{ print "test LSIDs\n";  testLSIDs() }
    case "R"	{ removeLSIDs() }
    case "Q"	{ print "Quit program\n";  last LOOP }
    else	{ print "invalid key pressed" }
  }
  print "\n";
}

# End of the main loop
# ====================

#doSQL($dbhImport, "show tables;");

# Close the statement and connections
# -----------------------------------

$stmt->finish;
$dbhCTL->disconnect;
$dbhImport1->disconnect;
$dbhImport2->disconnect;

print "\nTaxon Matcher has finished\n\n";

endLogFile();

# Subroutines
# -----------

sub ask_user
# Subroutine to prompt user for variable value, with default
{ print "$_[0] [$_[1]]: ";
  my $rc = <>;
  chomp $rc;
  if($rc eq "") { $rc = $_[1]; }
  return $rc;
}

sub getKey
# Get the user's response to a menu choice
{ print "---press one of the specified keys------------------------------------------\n";
  ReadMode 'cbreak';
  $letter = ReadKey(0);
  ReadMode 'normal';
  $letter=~ tr/[a-z]/[A-Z]/;  # force letters to upper case
  printOrLog("$letter key pressed");
  print "$letter:  ";
  return $letter;
}

sub connectDatabase
# Subroutine to connect to the specified database
{ my $databaseName= $_[0];
  my $database= $_[1];
  my $handle;
  printAndLogEntry("Connecting to the $databaseName database \"$database\" ...");

  if ($driver eq "ODBC")
  { $handle= DBI->connect("DBI:ODBC:$database", $userName, $password,
  			{RaiseError=>0, RaiseError=>0});
  }
  elsif ($driver eq "MySQL")
  { # Non-ODBC version used:
    $handle= $drh->connect("DBI:mysql:host=$server;port=3306;database=$database", $userName, $password,
			{RaiseError=>0, RaiseError=>0});
  }
  return $handle;
}

sub testDatabaseConnection
# Subroutine to test the connection to a database
{ my $handle= $_[0];
  if ($handle)
  { # Report success
    printAndLogEntry("... succeeded");
  }
  else
  { # Report failure
    printAndLogEntry("... failed: " . DBI->errstr);
    showHelp1();
    endLogFile();
    die "\n*** Cannot continue without a database connection!\n";
  }
}

sub showHelp1
{ print "\n\nPossible causes of this error:\n",
        "- the Cumulative Taxon List database (\"$taxonList\") has not already been created\n";
  if ($driver eq "ODBC")
  { print "- an ODBC database driver for Perl has not been set up correctly\n",
          "- a database has not had an ODBC data source name set up correctly\n",
          "- the database is inaccessible because the client machine is not connected to the Internet\n",
          "- the database server is down\n";
  }
  print "Please refer to the Taxon Matcher user manual\n";
}

sub runSQL
# (database handle, SQL statement)
# Subroutine to execute an SQL statement
# and return true if it succeeded or false if it failed
{ my ($handle, $statement)= @_;
  # Create an SQL statement (note: this is a global handle, 
  # used by showResult() for fetching the result data
  $stmt= $handle->prepare($statement);
  # Execute the statement
  my $result= $stmt->execute;
  return defined $result;
}

sub doSQL
# (database handle, SQL statement)
# Subroutine to execute an SQL statement
{ my ($handle, $statement)= @_;
  # Execute an SQL statement
  printOrLogEntry("   executing SQL statement ...\n\t$statement");          
  $startTime= time;
  if (runSQL($handle, $statement))
  { # Report success
    my $elapsedTime= int(time - $startTime);
    # Create an SQL statement to count the number of affected records,
    # using a local handle to preserve any results associated with the global one
    my $stmt= $handle->prepare("SELECT ROW_COUNT();");
    # Execute the statement
    $stmt->execute;
    @result = $stmt->fetchrow_array;
    my $showRecords= $result[0] > 0;
    my $records= $showRecords ? sprintf("%52d records", $result[0]) : " "x60;
    if ($elapsedTime >= 60)
    { $minutes= int($elapsedTime/60);  
      $seconds= $elapsedTime - $minutes*60;
      $time= sprintf("%7d min %2d s", $minutes, $seconds);
    }
    else
    { $time= sprintf("%8d seconds", $elapsedTime);
    }
    printAndLog($records . $time) if $showRecords or $elapsedTime > 1.5;     
  }
  else
  { # Report failure
    printAndLogEntry("*** SQL failed: " . DBI->errstr);   
    endLogFile();
    die "\n*** $programName will halt, in case the comparison database is unusable\n";
  }
}

sub showResult # (limit)
# Display a result table (with row numbers unless limit = 1)
{ my ($limit)= @_;
  my $record;
  $limit= $showLimit unless defined $limit;
  $limit= 100000 if $limit == 0;
  # Print and log the fields of every record returned
  $recordNr= 0;
  while ($recordNr++ != $limit and @result = $stmt->fetchrow_array)
  { if ($recordNr % 20 == 0)
    { print "Press Enter to continue ...";  
      <>;
    }
    $record= $result[0];
    $record= (sprintf("%8d: ", $recordNr) . $record) if $limit > 1;
    foreach $field (@result[1..$#result])
    { $field= "<null>" unless defined($field);
      $record.= "\t| $field"; 
    }
    $record= "<no result>" unless defined $record;
    printAndLog($record);
  }
  printAndLog("(reached display limit of $limit records)") 
    if $limit > 1 && $recordNr == $limit;
} # showResult()

sub listMatches
# List, for every GSD, the number of matched records and unmatched records
# in the 2008 and 2009 databases
{ doSQL($dbhCTL, "SELECT   count(*), $database[1].databases.database_name 
                   FROM Taxon, $database[1].databases
                   WHERE databaseId = $database[1].databases.record_id
                   GROUP BY databaseId;");
  showResult();
}

sub showMatches
{ doSQL($dbhCTL, "SELECT   edition, id, code,
                            allData, nameCodes, lsid
                   FROM Taxon
                   WHERE sciNames like 'Allo%'
                   ORDER BY allData, edition
                   $showLimitClause;");
  showResult();
}

sub showHelp
{ print "show Help text\n"
      . "\n------------------------------------------------------------------------------------\n\n";
  my $result= system("more TaxonMatcher.txt");
  print "\nResult = $result, \$\? = $?\n" unless $result == 0;
  print "\n------------------------------------------------------------------------------------\n";
}

sub showOptions
{ printAndLogEntry("Current options:");
  printAndLog("                 user: $user");
  printAndLog("                   OS: $OS");
  printAndLog("               server: $server");
  printAndLog("                 user: $userName, password: $password");    
  printAndLog("     import databases: $databaseImport1, $databaseImport2");    
  printAndLog("Cumulative Taxon List: $taxonList");    
  printAndLog("         logging file: $logFileName, will "
            . ($clearLogFile ? "" : "not ") . "be cleared");
  printAndLog("        record limits: $readLimit read, $showLimit displayed");
  printOrLog ("     (if a limit is 0, no limit is applied)");
  printAndLog("    taxon name filter: $readNames");
} # showOptions()

sub changeOptions
{ showOptions();
  # Start of loop for changing options
OPTIONLOOP:
  for (;;)  # infinite loop
  { # Display the options menu
    print "\n---Change options-----------------------------------------------------------\n"
        . "S:  Server and user  	B:  deBugging and limits\n"
        . "D:  Databases        	O:  show current Option values\n"
        . "L:  Logging options  	Q:  Quit (accept current option values)\n";
    # Execute the user's selected test
    switch (getKey)
    { case "S"	{ setServerOptions() }
      case "D"	{ setDatabaseOptions() }
      case "L"	{ setLoggingOptions() }
      case "B"	{ setDebugOptions() }
      case "O"	{ showOptions() }
      case "Q"	{ print "Quit (accept current option values)";  last OPTIONLOOP }
      else	{ print "invalid key pressed" }
    }
  }
  # End of loop for changing options
  showOptions();
}  
  
sub setServerOptions
# Prompt the user for connection information
{ print "\nPlease enter database connection details\n"
      . "(just press the Enter key to accept the previous or default values shown)\n\n";
  if ($driver eq "MySQL")
  { # Needed for non-ODBC version
    $server=        ask_user ("server", "biodiversity.cs.cf.ac.uk");
  }
  $userName=        ask_user ("            user name", $userName);
  $password=        ask_user ("             password", $password);   
  connectDbs(); 
}

sub setDatabaseOptions
{ $databaseImport1= ask_user ("  1st import database", $databaseImport1);
  $databaseImport2= ask_user ("  2nd import database", $databaseImport2);
  $taxonList=       ask_user ("Cumulative Taxon List", $taxonList);
}

sub setLoggingOptions  
{ endLogFile();
  $logFileName=     ask_user ("\nName of logging file", $logFileName);
  if ($logFileName)
  { if (-s $logFileName)
    { $clearLogFile=    ask_user ("Clear this log file?", $clearLogFile);
      if ($clearLogFile =~ /^[Yy].+/)
      { unlink($logFileName);
        $clearLogFile= "n";
      }
      beginLogFile ($logFileName);
    }
  }
}

sub setLimitClauses
{ $readLimitClause= $readLimit > 0 ? "LIMIT $readLimit" : "";
  $showLimitClause= $showLimit > 0 ? "LIMIT $showLimit" : "";
  # Define $readNames 
  # (in case it's not included in an old TaxonMatcher.config file)
  $readNames= "" unless defined $readNames;
  # WHERE clauses for restricted subsets using $readNames need to
  # be programmed individually to suit the SQL where they are used
}

sub setDebugOptions
{ $readLimit=       ask_user ("   limit records read", $readLimit);  
  $showLimit=       ask_user ("limit lines displayed", $showLimit);
  setLimitClauses();
}

sub connectDbs
# Establish connections to the databases
{ printAndLog("Setting up database connections");
  print "\n";

  $dbhCTL= connectDatabase ("Cumulative Taxon List", $taxonList);
  if (not defined($dbhCTL) and $driver eq "MySQL")
  { # Try to create the database if using a non-ODBC MySQL driver
    $dbhCTL= $drh->connect("DBI:mysql:host=$server;port=3306", $userName, $password,
  			{RaiseError=>0, RaiseError=>0});
    #doSQL($dbhCTL, "drop database $taxonList;");
    doSQL($dbhCTL, "create database if not exists $taxonList;");
    $dbhCTL->disconnect;
    $dbhCTL= connectDatabase ("Cumulative Taxon List", $taxonList);
  }
  testDatabaseConnection ($dbhCTL);
  
  $dbhImport1= connectDatabase ("1st import", $databaseImport1);
  testDatabaseConnection ($dbhImport1);
  $dbhImport1->{PrintError}= 0;
  $lsidsPresent[0]= runSQL($dbhImport1, "SELECT lsid FROM taxa LIMIT 1;");
  $dbhImport1->{PrintError}= 1;
  printAndLog("$databaseImport1 "
            . ($lsidsPresent[0] ? "contains" : "does not contain") . " an LSID field");
  $dbhImport2= connectDatabase ("2nd import", $databaseImport2);
  testDatabaseConnection ($dbhImport2);
  $dbhImport2->{PrintError}= 0;
  $lsidsPresent[1]= runSQL($dbhImport2, "SELECT lsid FROM taxa LIMIT 1;");
  $dbhImport2->{PrintError}= 1;
  printAndLog("$databaseImport2 "
            . ($lsidsPresent[1] ? "contains" : "does not contain") . " an LSID field");
  
  # Permit long field values in the CTL to be handled by ODBC
  $dbhCTL->{LongReadLen}= 16384;  # increases the limit
  #$dbhCTL->{LongTruncOk}= 1;      # stops error messages
  
  # Increase the maximum allowed length for a MySQL "GROUP_CONCAT" function result 
  # (this is used to populate the concatNames and concatData fields)
  doSQL($dbhCTL, "SET group_concat_max_len = 15000;");
  
  printAndLog("      database driver: $driver");
  printAndLog("  ODBC driver version: " . $DBD::ODBC::VERSION)
    if $driver eq "ODBC";
}

sub countTaxa
{ printAndLogEntry("Number of records in Taxon table");
  doSQL($dbhCTL, "SELECT COUNT(*) FROM Taxon;");
  showResult(1);
}

sub countTaxaWithLsids
{ printAndLogEntry("Number of taxa with LSIDs"); 
  doSQL($dbhCTL, "SELECT COUNT(*) FROM Taxon WHERE LENGTH(lsid) = 36;");
  showResult(1);
  print "\n";
}

sub emptyCTL
# Run SQL commands to set up the Cumulative Taxon List database
# -------------------------------------------------------------
{ print "Empty comparison database\n";
  doSQL($dbhCTL, "DROP TABLE IF EXISTS $taxonList.Taxon;");
  print "\nNow you need to import two Annual Checklist editions.";
}

sub chooseEdition
# Choose an Annual Checklist database to test or import
# -----------------------------------------------------
{ my ($task)= @_;
EDITION:
  print "\n---Choose an Annual Checklist edition $task-------------------\n"
      . "1:  $databaseImport1	2:  $databaseImport2\n";
  print "C:  use the Current AC database ($edition[$currentEdition]: $database[$currentEdition])\n" 
    if defined($currentEdition);
  # Choose the user's selected edition
  switch (getKey)
  { case "1"	{ $currentEdition= 0 }
    case "2"	{ $currentEdition= 1 }
    case "C"	{ }
    else	{ print "invalid key pressed\n";  goto EDITION }
  }
  print "\n\nUsing AC database $edition[$currentEdition] ($database[$currentEdition])\n";
  doSQL($dbhCTL, "USE $database[$currentEdition]");
}

sub testAC
# Perform various tests on an Annual Checklist database
# -----------------------------------------------------
{ print "test AC edition\n"; 
  chooseEdition("to test");

  # Start of AC tests loop
ACTESTLOOP:
  for (;;)  # infinite loop
  { # Display the main menu
    print "\n---Annual Checklist test menu-----------------------------------------------\n"
        . "1:  test name_code values	C:  Change AC edition\n"
        . "2:  test synonymic higher taxa	L:  test LSIDs in AC edition\n"
        . "3:  synonymic status errors	A:  perform All tests\n"
        . "4:  list infra-specific ranks (30s)	Q:  Quit (back to main menu)\n";
    # Execute the user's selected test
    switch (getKey)
    { case "A"	{ print "perform All tests\n";
                  testAC1();  testAC2();  
                  testAC3();  testAC4();  
		  testLSIDs()
                }
      case "1"	{ testAC1() }
      case "2"	{ testAC2() }
      case "3"	{ testAC3() }
      case "4"	{ testAC4() }
      case "C"	{ chooseEdition("to test") }
      case "L"	{ testLSIDs() }
      case "Q"	{ print "Quit (back to main menu)";  last ACTESTLOOP }
      else	{ print "invalid key pressed" }
    }
  }
  # End of AC tests loop
}

sub importAC
# Run SQL commands for the import databases
# -----------------------------------------
{ print "Import AC edition\n";
  chooseEdition("to import");
  $ed= $edition[$currentEdition];
  $db= $database[$currentEdition];
  $lsids= $lsidsPresent[$currentEdition];
  if ($lsids)
  { print "The Annual Checklist $ed contains LSIDs\n";
    # Extract only the UUID part of the previous LSIDs
    $lsidValue= "SUBSTRING(AC.lsid FROM 36 FOR 36)";
  }
  else
  { print "The Annual Checklist $ed does not contain LSIDs\n";
    $lsidValue= "NULL";
  }

  doSQL($dbhCTL, "USE $taxonList");

  print "\nThe next few SQL statements may take several minutes each"
      . " if working with the full databases.  Please be patient.\n"
    if $readLimit > 20000;

  # Create the Taxon table, if necessary
  # (the index on id didn't seem to do much good, but I am
  # reluctant to add a corresponding index to, say, common_names.name_code
  # because it would involve an invasive change to the AC database)  
  doSQL($dbhCTL, "CREATE TABLE IF NOT EXISTS Taxon
                (edition      VARCHAR(6) NOT NULL DEFAULT '',
                 edRecordId   INT(10) UNSIGNED NOT NULL,
		 databaseId   INT(10) UNSIGNED,
		 code         VARCHAR(137) NOT NULL DEFAULT '',
		 lsid         VARCHAR(36),
		 rank         VARCHAR(12),
		 nameCodes    TEXT,
		 sciNames     TEXT,
		 commonNames  TEXT,
		 distribution TEXT,
		 otherData    TEXT,
		 allData      TEXT NOT NULL DEFAULT '',
		 INDEX        (edition),
		 INDEX        (edRecordId),
		 INDEX        (code),
		 INDEX        (lsid));");

  countTaxa();
  print "\n";

  printAndLogEntry("Importing Annual Checklist taxon data records from $db");
  doSQL($dbhCTL, "ALTER TABLE Taxon DISABLE KEYS;");
  print "\n";

  # Store names of species-level taxa (with complete synonymy) 
  printAndLogEntry("Importing species and lower taxa, with synonyms");
  $whereClause= $readNames eq "" ? "" : "WHERE genus LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, rank,
                           nameCodes, sciNames, otherData)
         SELECT '$ed', 0, S.database_id, S.accepted_name_code, '(sp/infra)',
                GROUP_CONCAT(S.name_code ORDER BY sp2000_status_id SEPARATOR '; '),
                GROUP_CONCAT(CONCAT_WS(' ', genus, species,
                                       NULLIF(infraspecies_marker, ''),
                                       infraspecies, author)
                                       ORDER BY sp2000_status_id, genus, species, 
                                                infraspecies, author
                                       SEPARATOR ', '),
                S.accepted_name_code
         FROM $db.scientific_names S $whereClause
         GROUP BY S.accepted_name_code $readLimitClause;"); 

  doSQL($dbhCTL, "ALTER TABLE Taxon ENABLE KEYS;");

  countTaxa();
  countTaxaWithLsids();

  # Copy the LSID values, if present (i.e. from the earlier AC)
  if ($currentEdition == 0)
  { printAndLogEntry("Importing LSIDs for species and lower taxa");
    doSQL($dbhCTL, 
           "UPDATE Taxon T, $db.taxa AC
           SET T.lsid= $lsidValue
           WHERE T.code = AC.name_code;");
    #     "UPDATE Taxon T LEFT JOIN $db.taxa AC ON T.code = AC.name_code
    #       SET T.lsid= AC.lsid;");
    countTaxa();
    countTaxaWithLsids();
  }

  #doSQL($dbhCTL, "ALTER TABLE Taxon DISABLE KEYS;");

  # Collect common names
  printAndLogEntry("Importing common names");
  doSQL($dbhCTL, "DROP TABLE IF EXISTS CommonName;");
  doSQL($dbhCTL, 
        "CREATE TABLE CommonName
          (edition     VARCHAR(6) NOT NULL DEFAULT '',
           code        VARCHAR(137) NOT NULL DEFAULT '',
           commonNames TEXT,
           INDEX (code))
         SELECT T.edition, T.code, 
                GROUP_CONCAT(CONCAT_WS('/', common_name, `language`, country)
                  ORDER BY common_name, `language`, country
                  SEPARATOR ', ') AS commonNames
         FROM Taxon T, $db.common_names C
         WHERE T.edition = '$ed' AND T.code = C.name_code
         GROUP BY C.name_code $readLimitClause;");
  # Copy common names to Taxon table
  doSQL($dbhCTL, 
  #     "UPDATE Taxon T
  #       LEFT JOIN CommonName C ON T.code = C.code
  #       SET T.commonNames= C.commonNames
  #       WHERE T.edition = '$ed';");
         "UPDATE Taxon T, CommonName C
         SET T.commonNames= C.commonNames
         WHERE T.code = C.code AND T.edition = '$ed';");
  # Don't add "AND C.commonNames IS NOT NULL" as this increases the query time
  doSQL($dbhCTL, "DROP TABLE CommonName;");
   
  # Store distributions
  printAndLogEntry("Importing distribution data");
  doSQL($dbhCTL, 
  #     "UPDATE Taxon T
  #       LEFT JOIN $db.distribution D ON T.code = D.name_code
  #       SET T.distribution= D.distribution
  #       WHERE T.edition = '$ed';");
         "UPDATE Taxon T, $db.distribution D
         SET T.distribution= D.distribution
         WHERE T.code = D.name_code AND T.edition = '$ed';");
   
  # Store other data (not used at present)
  
  printAndLogEntry("Importing genera");
  $whereClause= $readNames eq "" ? "" : "AND AC.name LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, AC.database_id, 
           CAST(AC.record_id AS CHAR), $lsidValue, 'Genus', '', 
           CONCAT_WS(': ', AC.name, P1.name, P2.name, P3.name, P4.name, P5.name)
         FROM $db.taxa AC, $db.taxa P1, $db.taxa P2, $db.taxa P3, $db.taxa P4, $db.taxa P5
         WHERE AC.taxon = 'Genus' AND AC.is_accepted_name = 1 $whereClause
           AND AC.parent_id = P1.record_id AND P1.parent_id = P2.record_id 
           AND P2.parent_id = P3.record_id AND P3.parent_id = P4.record_id 
           AND P4.parent_id = P5.record_id $readLimitClause;");   
        
  printAndLogEntry("Importing families");
  $whereClause= $readNames eq "" ? "" : "AND family LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames, otherData)
         SELECT '$ed', AC.record_id, F.database_id, 
                CONCAT_WS(': ', family, `order`, class, phylum, kingdom),
                $lsidValue, 'Family', hierarchy_code, 
                if(superfamily = '' or superfamily is null, 
                CONCAT_WS(': ', family, `order`, class, phylum, kingdom),
                CONCAT_WS(': ', family, superfamily, `order`, class, phylum, kingdom)),
                AC.name
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Family' AND name = family $whereClause $readLimitClause;");   
   
  printAndLogEntry("Importing superfamilies");
  $whereClause= $readNames eq "" ? "" : "AND superfamily LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, F.database_id, 
                CONCAT_WS(': ', superfamily, `order`, class, phylum, kingdom), 
                $lsidValue, 'Superfamily', hierarchy_code, 
                CONCAT_WS(': ', superfamily, `order`, class, phylum, kingdom)
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Superfamily' AND name = superfamily $whereClause
         GROUP BY superfamily, `order` $readLimitClause;");   
   
  printAndLogEntry("Importing orders");
  $whereClause= $readNames eq "" ? "" : "AND `order` LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, F.database_id,
                CONCAT_WS(': ', `order`, class, phylum, kingdom), 
                $lsidValue, 'Order', hierarchy_code, 
                CONCAT_WS(': ', `order`, class, phylum, kingdom)
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Order' AND name = `order` $whereClause
         GROUP BY `order`, class $readLimitClause;");   
   
  printAndLogEntry("Importing classes");
  $whereClause= $readNames eq "" ? "" : "AND class LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, F.database_id,
                CONCAT_WS(': ', class, phylum, kingdom), 
                $lsidValue, 'Class', hierarchy_code, 
                CONCAT_WS(': ', class, phylum, kingdom)
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Class' AND name = class $whereClause
         GROUP BY class, phylum $readLimitClause;");   
   
  printAndLogEntry("Importing phyla");
  $whereClause= $readNames eq "" ? "" : "AND phylum LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, F.database_id,
                CONCAT_WS(': ', phylum, kingdom), 
                $lsidValue, 'Phylum', hierarchy_code, 
                CONCAT_WS(': ', phylum, kingdom)
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Phylum' AND name = phylum $whereClause
         GROUP BY phylum, kingdom $readLimitClause;");   
   
  printAndLogEntry("Importing kingdoms");
  $whereClause= $readNames eq "" ? "" : "AND kingdom LIKE '$readNames'";
  doSQL($dbhCTL, 
       "INSERT INTO Taxon (edition, edRecordId, databaseId, code, lsid, rank, 
                           nameCodes, sciNames)
         SELECT '$ed', AC.record_id, F.database_id,
                kingdom, $lsidValue, 'Kingdom', hierarchy_code, 
                CONCAT_WS(': ', kingdom, '(top-level domain)')
         FROM $db.families F, $db.taxa AC
         WHERE taxon = 'Kingdom' AND name = kingdom $whereClause
         GROUP BY kingdom $readLimitClause;");   

  doSQL($dbhCTL, "ALTER TABLE Taxon ENABLE KEYS;");

  countTaxa();
  countTaxaWithLsids();
   
  # (Note: Could ask user how much data is to be compared)
  printAndLogEntry("Combining taxon data for later comparison");
  doSQL($dbhCTL, 
       "UPDATE Taxon
	SET allData= REPLACE(CONCAT_WS('; ', 
			TRIM(sciNames), TRIM(commonNames), 
			TRIM(distribution), TRIM(otherData)),
			'  ', ' ');");
  print "\n";

  printAndLogEntry("Finished importing Annual Checklist taxon data from $db");
}

sub compareEditions
# Compare taxa in the two editions in order to use old LSIDs or allocate new ones
{ print "Compare AC editions $edition[0] and $edition[1]\n";

  # This is a check to confirm that both AC editions have been imported
  printAndLogEntry("Number of taxa in edition $edition[0]"); 
  doSQL($dbhCTL, "SELECT COUNT(*) FROM Taxon WHERE edition = '$edition[0]';");
  showResult(1);
  printAndLogEntry("Number of taxa in edition $edition[1]"); 
  doSQL($dbhCTL, "SELECT COUNT(*) FROM Taxon WHERE edition = '$edition[1]';");
  showResult(1);
  print "\n";

  # Preparations to make the comparison run faster
  # Note: "ENGINE = MyISAM" is a fix for Luvie Paglinawan at the WorldFish centre in Los Banos, 
  # Philippines, running MySQL as a front end to MS Access or SQL Server: the Taxon table must 
  # use the MyISAM engine, as an INDEX on a TEXT field is supported only on the MyISAM table type.
  printAndLogEntry("Prepare table before comparing taxa in editions"); 
  doSQL($dbhCTL, "ALTER TABLE Taxon ENGINE = MyISAM;");
  doSQL($dbhCTL, "ALTER TABLE Taxon ADD INDEX (allData(100));"); 
  doSQL($dbhCTL, "ALTER TABLE Taxon ENABLE KEYS;");
  doSQL($dbhCTL, "OPTIMIZE TABLE Taxon;");
  
  printAndLogEntry("Comparing taxa to find old LSIDs from edition $edition[0]"); 
  #doSQL($dbhCTL, "LOCK TABLES Taxon;");
  doSQL($dbhCTL, 
         "UPDATE Taxon T1, Taxon T2
           SET T2.lsid= T1.lsid
         WHERE T1.allData = T2.allData
           AND T1.edition = '$edition[0]' 
           AND T2.edition = '$edition[1]';");
  #      "UPDATE Taxon T1,
  #        (SELECT T2.edition, T2.lsid, COUNT(T2.allData) AS matched
  #         FROM Taxon T2
  #         GROUP BY T2.allData HAVING matched > 1) AS dups
  #       SET T1.lsid= dups.lsid
  #       WHERE T1.id = dups.id;");
  printAndLog("(number of matched (old) taxa is shown)");
  print "\n";

  #doSQL($dbhCTL, "UNLOCK TABLES;");

  printAndLogEntry("Creating new LSIDs for edition $edition[1]"); 
  doSQL($dbhCTL, 
         "UPDATE Taxon
           SET lsid= UUID()
         WHERE edition = '$edition[1]' AND lsid IS NULL;");
  printAndLog("(number of unmatched (new) taxa is shown)");
}

sub showStatistics
# Process the Cumulative Taxon List database
# ------------------------------------------
{ print "comparison Statistics and tests\n";

  #doSQL($dbhCTL, "USE $taxonList");

  # Index database (index currently included when table created)

  # Test for matches
  #doSQL($dbhCTL, "SELECT * FROM Taxon 
  #                ORDER BY sciNames, commonnames, distribution, otherData;");
  #showResult();

  matches:
  print "\nNumber of matched and unmatched taxa, by GSD:\n";
  listMatches();
  #showMatches();
  
  # Start of statistics and tests loop
STATLOOP:
  for (;;)  # infinite loop
  { # Display the main menu
    print "\nComparison statistics and tests menu\n"
        . "A:  display All results	1:  statistics ***\n"
        . "2:  statistics ***		Q:  Quit (back to main menu)\n";

    # Execute the user's selected test
    switch (getKey)
    { case "A"	{ print "display All results\n";
                  stats1();  stats2()
                }
      case "1"	{ stats1() }
      case "2"	{ stats2() }
      case "Q"	{ print "Quit (back to main menu)\n";  last STATLOOP }
      else	{ print "invalid key pressed\n" }
    }
  }
  # End of statistics and tests loop  
}

sub addLSIDs
# Add LSID values to the 2009 database
{ print "Add LSIDs to AC edition\n";
  # Add the LSID field to the 2009 database
  if ($lsidsPresent[1])
  { print "Import database $database[1] already contains LSID field\n";
  }
  else
  { printAndLogEntry("Create the lsid field in database $database[1]");
    doSQL($dbhCTL, "USE $database[1]");
    doSQL($dbhCTL, 
           "ALTER TABLE taxa ADD COLUMN lsid VARCHAR(78) AFTER `record_id`;");
    $lsidsPresent[1]= 1;
    print "\n";
  }

  printAndLogEntry("Add stop-gap UUIDs to all accepted taxa");
  # (will later mostly be replaced by UUIDs from the Taxon table)
  doSQL($dbhCTL, "UPDATE taxa SET lsid= UUID() WHERE is_accepted_name = 1;"); 
  print "\n";

  printAndLogEntry("Copying UUID values to the new Annual Checklist"); 
  doSQL($dbhCTL, "USE $taxonList");
  printAndLogEntry("Species and lower taxa"); 
  doSQL($dbhCTL, 
         "UPDATE $database[1].taxa A, Taxon T
         SET A.lsid= T.lsid
         WHERE T.edition = '$edition[1]' AND A.is_accepted_name = 1
           AND T.code = A.name_code;");   
  printAndLogEntry("Genera and higher taxa"); 
  doSQL($dbhCTL, 
         "UPDATE $database[1].taxa A, Taxon T
         SET A.lsid= T.lsid
         WHERE T.edition = '$edition[1]' AND A.is_accepted_name = 1
           AND T.edRecordId = A.record_id;");   
  #printAndLogEntry("Genera"); 
  #doSQL($dbhCTL, 
  #       "UPDATE $database[1].taxa A, Taxon T
  #       SET A.lsid= T.lsid
  #       WHERE T.edition = '$edition[1]' AND A.is_accepted_name = 1
  #         AND T.code = CAST(A.record_id AS CHAR);");   
  #printAndLogEntry("Higher taxa"); 
  #doSQL($dbhCTL, 
  #      "UPDATE $database[1].taxa A, Taxon T
  #      SET A.lsid= T.lsid
  #      WHERE T.edition = '$edition[1]' AND A.is_accepted_name = 1
  #        AND T.code = A.name AND A.taxon != 'Genus';");   
  print "\n";
  printAndLogEntry("Format all UUID values into LSIDs"); 
  doSQL($dbhCTL, 
         "UPDATE $database[1].taxa
         SET lsid= CONCAT('$prefixLSID', lsid, ':$edition[1]')
         WHERE is_accepted_name = 1;");   
  print "\n";
}

sub removeLSIDs
# Remove the LSID field from the 2009 database
# (this is to allow it to be used with the old user interface)
{ if ($lsidsPresent[1])
  { printAndLogEntry("Remove the lsid field in database $database[1]");
    doSQL($dbhCTL, "USE $database[1]");
    doSQL($dbhCTL, "ALTER TABLE taxa DROP COLUMN lsid;");
    $lsidsPresent[1]= 0;
    print "\n";
  }
  else
  { print "Import database $database[1] does not contain an LSID field\n";
  }
}

# Database test functions
# =======================

sub testAC1
{ printAndLogEntry("Annual Checklist ($edition[$currentEdition]) test 1:");
  printAndLog("name_code values which occur more than once");
  doSQL($dbhCTL, 
         "SELECT name_code, count(*) AS total 
         FROM scientific_names
         GROUP BY name_code HAVING total != 1;");
  showResult();
}

sub testAC2
{ printAndLogEntry("Annual Checklist ($edition[$currentEdition]) test 2:");
  printAndLog("synonymic higher taxa");
  doSQL($dbhCTL, 
         "SELECT taxon, is_species_or_nonsynonymic_higher_taxon, 
                 count(*) AS total 
         FROM taxa 
         GROUP BY taxon, is_species_or_nonsynonymic_higher_taxon;");
  showResult();
}

sub testAC3
{ printAndLogEntry("Annual Checklist ($edition[$currentEdition]) test 3:");
  printAndLog("errors in synonymic status");
  doSQL($dbhCTL, 
         "SELECT sp2000_status_id, is_accepted_name, 
                 (name_code != accepted_name_code) AS synonym, count(*) AS total 
         FROM scientific_names 
         GROUP BY sp2000_status_id, is_accepted_name, synonym;");
  showResult();
}

sub testAC4
{ printAndLogEntry("Annual Checklist ($edition[$currentEdition]) test 4:");
  print "\n";
  printAndLogEntry("Infra-specific rank markers in accepted names");
  doSQL($dbhCTL, 
         "SELECT count(*), infraspecies_marker
         FROM scientific_names WHERE is_accepted_name = 1
         GROUP BY infraspecies_marker WITH ROLLUP;");
  showResult();
  printAndLog("(last line is total count)");
  print "\n";
  printAndLogEntry("Infra-specific rank markers in synonyms");
  doSQL($dbhCTL, 
         "SELECT count(*), infraspecies_marker
         FROM scientific_names WHERE is_accepted_name = 0
         GROUP BY infraspecies_marker WITH ROLLUP;");
  showResult();
  printAndLog("(last line is total count)");
}

sub testLSIDs
{ chooseEdition("to test LSIDs");
  printAndLogEntry("Annual Checklist ($edition[$currentEdition]):");
  if ($lsidsPresent[$currentEdition])
  { print "\n";
    printAndLogEntry("Number of missing or malformed LSIDs");
    doSQL($dbhCTL, 
           "SELECT count(name), is_species_or_nonsynonymic_higher_taxon
           FROM taxa 
           WHERE is_accepted_name = 1 
           AND NOT lsid LIKE '$prefixLSID%:$edition[$currentEdition]'
           GROUP BY is_species_or_nonsynonymic_higher_taxon;");
    showResult();
    printAndLog("(no output implies no missing or malformed LSIDs were found)");
    printAndLogEntry("List taxa with missing or malformed LSIDs");
    doSQL($dbhCTL, 
           "SELECT taxon, name, lsid, is_species_or_nonsynonymic_higher_taxon
           FROM taxa 
           WHERE is_accepted_name = 1 
           AND NOT lsid LIKE '$prefixLSID%:$edition[$currentEdition]'
           ORDER BY taxon, name;");
    showResult();
    printAndLogEntry("Number of non-unique LSIDs");
    doSQL($dbhCTL, 
           "SELECT IFNULL(SUM(number_of_duplicates), 0) 
           FROM (SELECT count(lsid) AS number_of_duplicates 
                 FROM taxa WHERE is_accepted_name = 1
                 GROUP BY lsid HAVING number_of_duplicates > 1) AS DupLsids;");
    showResult(1);
    print "\n";
    printAndLogEntry("List taxa with non-unique LSIDs");
    doSQL($dbhCTL, 
           "SELECT lsid, count(lsid) AS number_of_duplicates, 
                   GROUP_CONCAT(name ORDER BY name SEPARATOR '; ')
           FROM taxa WHERE is_accepted_name = 1
           GROUP BY lsid HAVING number_of_duplicates > 1;");
    showResult();
    printAndLog("(no output implies no duplicated LSIDs were found)");
    #print "\n";
    #printAndLogEntry("Unmatch taxa with non-unique LSIDs");
    #doSQL($dbhCTL, 
    #       "DELETE FROM $taxonList.Taxon 
    #       WHERE otherData IN (SELECT name
    #       FROM taxa WHERE is_accepted_name = 1
    #       GROUP BY lsid HAVING count(lsid) > 1);");
    #showResult();
    #printAndLog("(If a few duplicated LSIDs were found, repeat step \"A\".)");
  }
  else
  { printAndLog("(the LSID field is not present:  run the \"A\" step first.)");
  }
}

sub stats1
{ printAndLogEntry("Database comparison statistics 1: *** not yet implemented");
}

sub stats2
{ printAndLogEntry("Database comparison statistics 2: *** not yet implemented");
}

# subroutines for logging
# =======================

sub beginLogFile ($) # (log file path and name)
# Initialise log file
{ my ($logFileName)= @_;
  open(logFile, ">$logFileName") 
    || die("Cannot make log file \"$logFileName\""); 
  $logging= 1;
  printf logFile "$logFileName: log file written by $programName (version $programVersion)\n"
               . "Date       time     log message\n"  
               . "---------- -------- -----------\n";    
  &printLogEntry("(log file \"$logFileName\" opened)");
} # beginLogFile

sub timestamp
# Create a timestamp for a log message
{ my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst)= gmtime;
  return sprintf("%02d/%02d/%4d %02d:%02d:%02d", 
                 $mday, $mon+1, $year+1900, $hour, $min, $sec);
} # timestamp

sub printLogEntry ($) # (message)
# Print a message heading line to the log file.
# The log file is closed after every write operation to
# ensure that it is up-to-date in the event of a crash.  
{ if ($logging) 
  { open(logFile, ">>$logFileName")
      || die("Cannot reopen log file \"$logFileName\"");
    my ($message)= @_;
    my $heading= &timestamp;
    print logFile "$heading $message\n";
    close(logFile);
  }
} # printLog

sub printLog ($) # (message)
# Print a message line (without a heading) to the log file.
# The log file is closed after every write operation to
# ensure that it is up-to-date in the event of a crash.  
{ if ($logging) 
  { open(logFile, ">>$logFileName")
      || die("Cannot reopen log file \"$logFileName\"");
    my ($message)= @_;
    print logFile "   $message\n";
    close(logFile);
  }
} # printLog

sub printOrLogEntry # (message)
{ my ($message)= @_;
  if ($logging) { &printLogEntry($message); }
  else          { print "$message\n"; }
} # printOrLog

sub printOrLog # (message)
{ my ($message)= @_;
  if ($logging) { &printLog($message); }
  else          { print "$message\n"; }
} # printOrLog

sub printAndLogEntry # (message)
{ my ($message)= @_;
  &printLogEntry($message);
  print "$message\n";
} # printAndLogEntry	

sub printAndLog # (message)
{ my ($message)= @_;
  &printLog($message);
  print "$message\n";
} # printAndLog	

sub endLogFile
# Close log file 
{ &printLogEntry("(log file \"$logFileName\" closed)");
  # No need to close(logFile); as currently it is always closed after use anyway
  $logging= 0;
} # endLogFile

# End of logging routines

# End of TaxonMatcher.pl
