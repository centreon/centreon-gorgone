##################################################
# CENTREON
#
# Source Copyright 2005 - 2015 CENTREON
#
# Unauthorized reproduction, copy and distribution
# are not allowed.
#
# For more informations : contact@centreon.com
#
##################################################

use strict;
use warnings;
use POSIX;

package gorgone::modules::centreon::mbi::libs::bi::MySQLTables;

# Constructor
# parameters:
# $logger: instance of class CentreonLogger
# $centreon: Instance of centreonDB class for connection to Centreon database
# $centstorage: (optionnal) Instance of centreonDB class for connection to Centstorage database
sub new {
	my $class = shift;
	my $self  = {};
	$self->{"logger"}	= shift;
	$self->{"centstorage"} = shift;
	if (@_) {
		$self->{"centreon"}  = shift;
	}
	bless $self, $class;
	return $self;
}

sub isPartitionEnabled {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $parts = 0;
	my $sth =  $db->query("select count(*) as activated from INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME = 'partition' and PLUGIN_STATUS='ACTIVE'");
	if (my $row = $sth->fetchrow_hashref()) {
 		if ($row->{'activated'} eq "1") {
 			$parts = 1;
 		}
 	}
 	return $parts;
	 
}

sub tableExists {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($name) = (shift);
	my $statement = $db->query("SHOW TABLES LIKE '".$name."'");
	if (!(my @row = $statement->fetchrow_array())) {
		return 0;
	}else {
		return 1;
	}
}

sub createTable {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($name, $structure, $mode) = @_;
	my $statement = $db->query("SHOW TABLES LIKE '".$name."'");
	if (!$self->tableExists($name)) {
		if (defined($structure)) {
			$logger->writeLog("DEBUG", "[CREATE] table [".$name."]");
   			$db->query($structure);
   			return 0;
		}else {
			$logger->writeLog("FATAL", "[CREATE] Cannot find table [".$name."] structure");
		}
	}
	return 1;
}

# create table data_bin with partitions
sub createParts {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	
	my ($start, $end, $tableStructure, $tableName, $column) = @_;
	if (!defined($tableStructure)) {
		$logger->writeLog("FATAL", "[CREATE] Cannot find table [".$tableName."] structure");
	}
	if ($self->tableExists($tableName)) {
		return 1;
	}
	$tableStructure =~ s/\n.*PARTITION.*//g;
	$tableStructure =~ s/\,[\n\s]+\)/\)/;
	$tableStructure .= " PARTITION BY RANGE(`".$column."`) (";
	my $timeObj = Time->new($logger,$db);
	my $runningStart = $timeObj->addDateInterval($start, 1, "DAY");
	 while ($timeObj->compareDates($end, $runningStart) > 0) {
	 	my @partName = split (/\-/, $runningStart);
	 	$tableStructure .= "PARTITION p".$partName[0].$partName[1].$partName[2]." VALUES LESS THAN (FLOOR(UNIX_TIMESTAMP('".$runningStart."'))),";
		$runningStart= $timeObj->addDateInterval($runningStart, 1, "DAY");
	 }
	my @partName = split (/\-/, $runningStart);
	$tableStructure .= "PARTITION p".$partName[0].$partName[1].$partName[2]." VALUES LESS THAN (FLOOR(UNIX_TIMESTAMP('".$runningStart."'))));";
	$logger->writeLog("DEBUG", "[CREATE] table partitionned [".$tableName."] min value: ".$start.", max value: ".$runningStart.", range:  1 DAY\n");
	$db->query($tableStructure);
	return 0;
}

sub updateParts {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($rangeEnd, $tableName) = @_;
	my $timeObj = Time->new($logger,$db);
	
	my $isPartitioned = $self->isTablePartitioned($tableName);
	if (!$isPartitioned) {
		$logger->writeLog("WARNING", "[UPDATE PARTS] partitioning is not activated for table [".$tableName."]");
	}else {
		my $range = $self->getLastPartRange($tableName);
		$range = $timeObj->addDateInterval($range, 1, "DAY");
        while ($timeObj->compareDates($rangeEnd, $range) >= 0) {
			$logger->writeLog("DEBUG", "[UPDATE PARTS] Updating partitions for table [".$tableName."] (last range : ".$range.")");
			my @partName = split (/\-/, $range);
			my $query = "ALTER TABLE `".$tableName."` ADD PARTITION (PARTITION `p".$partName[0].$partName[1].$partName[2]."` VALUES LESS THAN(FLOOR(UNIX_TIMESTAMP('".$range."'))))";
			$db->query($query);
			$range = $timeObj->addDateInterval($range, 1, "DAY");
		}
	}
}

sub isTablePartitioned {
	my $self = shift;
	my $tableName = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	
	my $sth = $db->query("SHOW TABLE STATUS LIKE '".$tableName."'");
	if (my $row = $sth->fetchrow_hashref()) {
		my $createOptions = $row->{"Create_options"};
		if (defined($createOptions) && $createOptions =~ m/partitioned/i) {
			return 1;
		} elsif (!defined($createOptions) || $createOptions !~ m/partitioned/i) {
			return 0;
		}
	}
	$logger->writeLog("FATAL", "[TABLE STATUS CHECK] Cannot check if table is partitioned [".$tableName."]");
}

sub getLastPartRange {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my $tableName = shift;
	
	my $query = "SELECT DATE_FORMAT(FROM_UNIXTIME(MAX(CONVERT(PARTITION_DESCRIPTION, SIGNED INTEGER))), '%Y-%m-%d') as lastPart ";
	$query .= "FROM INFORMATION_SCHEMA.PARTITIONS ";
	$query .= "WHERE TABLE_NAME='".$tableName."' ";
	$query .= "AND TABLE_SCHEMA='".$db->db."' ";
	
	my $partName = undef;
	my $sth = $db->query($query);
	if (my $row = $sth->fetchrow_hashref()) {
		$partName = $row->{"lastPart"};
	}else {
		$logger->writeLog("FATAL", "[UPDATE PARTS] Cannot find table [data_bin] in database");
	}
	return($partName);
}

sub deleteEntriesForRebuild {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($start, $end, $tableName) = @_;
	
	if (!$self->isTablePartitioned($tableName)) {
		$db->query("DELETE FROM ".$tableName." WHERE time_id >= UNIX_TIMESTAMP('".$start."') AND time_id < UNIX_TIMESTAMP('".$end."')");
	}else {
		my $query = "SELECT partition_name FROM information_schema.partitions ";
		$query .= "WHERE table_name='".$tableName."' AND table_schema='".$db->db."'";
		$query .= " AND CONVERT(PARTITION_DESCRIPTION, SIGNED INTEGER) > UNIX_TIMESTAMP('".$start."')";
		$query .= " AND CONVERT(PARTITION_DESCRIPTION, SIGNED INTEGER) <= UNIX_TIMESTAMP('".$end."')";
		my $sth = $db->query($query);
		while(my $row = $sth->fetchrow_hashref()) {
			$db->query("ALTER TABLE ".$tableName." TRUNCATE PARTITION ".$row->{'partition_name'});	
		}
		$self->updateParts($end, $tableName);	
	}	
}

sub emptyTableForRebuild {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my $tableName = shift;
	my $structure = shift;
	my $column = shift;
	
	$structure =~ s/KEY.*\(\`$column\`\)\,//g;
	$structure =~ s/KEY.*\(\`$column\`\)//g;
	$structure =~ s/\,[\n\s+]+\)/\n\)/g;
	if (!defined($_[0]) || !$self->isPartitionEnabled()) {
		$db->query("DROP TABLE IF EXISTS ".$tableName);
		$db->query($structure);
	}else {
		my ($start, $end) = @_;
		$db->query("DROP TABLE IF EXISTS ".$tableName);
		$self->createParts($start, $end, $structure, $tableName, $column);		
	}
	$db->query("ALTER TABLE `".$tableName."` ADD INDEX `idx_".$tableName."_".$column."` (`".$column."`)");
}

sub dailyPurge {
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	
	my ($retentionDate, $tableName, $column) = @_;
	if (!$self->isTablePartitioned($tableName)) {
		$db->query("DELETE FROM `".$tableName."` WHERE ".$column." < UNIX_TIMESTAMP('".$retentionDate."')"); 
	}else {
		my $query = "SELECT GROUP_CONCAT(partition_name SEPARATOR ',') as partition_names FROM information_schema.partitions ";
		$query .= "WHERE table_name='".$tableName."' AND table_schema='".$db->db."'";
		$query .= " AND CONVERT(PARTITION_DESCRIPTION, SIGNED INTEGER) < UNIX_TIMESTAMP('".$retentionDate."')";
		my $sth = $db->query($query);
		if(my $row = $sth->fetchrow_hashref()) {
			if (defined($row->{'partition_names'}) && $row->{'partition_names'} ne "") {
				$db->query("ALTER TABLE ".$tableName." DROP PARTITION ".$row->{'partition_names'});
			}	
		}
	}
}

sub checkPartitionContinuity{
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($table)  = @_;
	my $message = "";
	my $query = "select CONVERT(1+datediff(curdate(),(select from_unixtime(PARTITION_DESCRIPTION) from information_schema.partitions";
	$query .= " where table_schema = '".$db->{"db"}."' and table_name = '".$table."' and PARTITION_ORDINAL_POSITION=1)), SIGNED INTEGER) as nbDays,";
	$query .= " CONVERT(PARTITION_ORDINAL_POSITION, SIGNED INTEGER) as ordinalPosition ";
	$query .= " from information_schema.partitions where table_schema = '".$db->{"db"}."' and table_name = '".$table."' order by PARTITION_ORDINAL_POSITION desc limit 1 ";
	my $sth = $db->query($query);
	while (my $row = $sth->fetchrow_hashref()) {
	my $nbDays = int($row->{'nbDays'});
	my $ordinalPosition = int($row->{'ordinalPosition'});
	my $dif = int($nbDays - $ordinalPosition);
	if($dif > 0){
  			$message .= "[".$table.", last partition:".$self->checkLastTablePartition($table)." missing ".$dif." part.]";
		}
	}
	$sth->finish;
	return($message);
}

sub checkLastTablePartition{
	my $self = shift;
	my $db = $self->{"centstorage"};
	my $logger = $self->{"logger"};
	my ($table)  = @_;
	my $message = "";
	my $query = "select from_unixtime(PARTITION_DESCRIPTION) as last_partition, IF(from_unixtime(PARTITION_DESCRIPTION)=CURDATE() AND HOUR(from_unixtime(PARTITION_DESCRIPTION))=0,1,0) as partition_uptodate ";
	$query .="from information_schema.partitions where table_schema = '".$db->{"db"}."'";
	$query .= "and table_name = '".$table."'order by PARTITION_ORDINAL_POSITION desc limit 1";
	my $sth = $db->query($query);
	while (my $row = $sth->fetchrow_hashref()) {
		if($row->{'partition_uptodate'} == 0){
			$message = $row->{'last_partition'};
		}
	}
	$sth->finish;
	return($message);
}

sub dropIndexesFromReportingTable {
	my $self = shift;
    my $table = shift;
	my $db = $self->{"centstorage"};
    my $indexes = $db->query("SHOW INDEX FROM ".$table);
    my $previous = "";
    while (my $row = $indexes->fetchrow_hashref()) {
        
        if ($row->{"Key_name"} ne $previous) {
            if (lc($row->{"Key_name"}) eq lc("PRIMARY")) {
                $db->query("ALTER TABLE `".$table."` DROP PRIMARY KEY");
            }else {
                $db->query("ALTER TABLE `".$table."` DROP INDEX ".$row->{"Key_name"});
            }
        }
        $previous = $row->{"Key_name"};
    }
}

1;
