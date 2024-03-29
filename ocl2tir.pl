#!/usr/bin/perl -w
use strict;
use warnings;

#external
use Getopt::Long;       #for command line options
use File::Slurp;
use File::Copy qw(copy);
use Parse::RecDescent;  #the parser module
use Regexp::Common;     #generate common regexs from this utility
use Data::Dumper;

#set clang and opt executables here
#The have to defined in the environment
my $CLANG =$ENV{"CLANG4TyBEC"};
my $OPT =$ENV{"OPT4TyBEC"};


#globals shared across packages
our $outTirBuff     = '';#string buffer for output TIR file
our %globalChannels;#hash for channels/pipes in global scope
our %cltCode;       #hash for tokens from parsed llvm code
our %tlut;          #hash for Translation LUT
our $linSize;       #linear size of array(s)

#locals
my $TyBECROOTDIR = $ENV{"TyBECROOTDIR"};



##--------------------------------
## files and output directory
##--------------------------------
my $inputFileOcl  = ''; 
my $outputFileTir = '';
my $callTybec     = '';

GetOptions (
    'i=s'   => \$inputFileOcl     #--i    <input C File> (required)
  , 'o=s'   => \$outputFileTir    #--o    <output TIR File> (optional)
  , 'ty'    => \$callTybec        #--ty   (if you want to call TyBEC on gen code)
  );

(my $filenameNoExt 	= $inputFileOcl) =~ s/\.[^.]+$//;

my $interimFileLlvm = $filenameNoExt.".ll"; #this will be generated by ocl2llvm.sh
#my $interimFileLlvm = $filenameNoExt.".ll.tmp"; #this will be generated by ocl2llvm.sh
#my $interimFileLlvm = "test_00_optimized.ll"; #this will be generated by ocl2llvm.sh

$outputFileTir      = $filenameNoExt.".tirl" if($outputFileTir eq '');

  
our $outputBuildDir = "build_".$filenameNoExt;

##--------------------------------
## run clang, generate llvm
##--------------------------------
print("******************************************************************\n");
print("OCL-to-LLVM-to-TIR (OLT) v0.1\n");
print("******************************************************************\n");
print("OLT:: Create output build directory: ok\n");
#system("rm -r $outputBuildDir");
mkdir($outputBuildDir) if !(-d $outputBuildDir);
chdir($outputBuildDir);

#bring in the soure .cl file into the build directory for convenience (switching between perl and bash)
#and also to keep a copy in build folder for later reference
copy("../$inputFileOcl" , ".");  


#call the ocl2llvm bash script
system(". ocl2llvm.sh $inputFileOcl");


##--------------------------------
## read in llvm
##--------------------------------
my $fhLlvm;
open($fhLlvm, "<", "$interimFileLlvm");
open($fhLlvm, "<", "$interimFileLlvm") 
  or die "Could not open file '$interimFileLlvm' $!";
my @llvmLines = grep { not /;.*/ } <$fhLlvm>; #remove comments while reading file
#chomp(my @llvmLines = <$fhLlvm>);
close $fhLlvm;  
print("OLT:: Read in optimizied llvm-IR: ok\n"); 

##--------------------------------
## convert to tir
##---------------

#read in grammar from file
my $cltGrammarFileName = "$TyBECROOTDIR/lib-intern/ocl2tir/llvmGrammar.pm"; 
open (my $cltFhTemplate, '<', $cltGrammarFileName)
 or die "Could not open file '$cltGrammarFileName' $!";     
our $cltGrammar = read_file ($cltFhTemplate);
close $cltFhTemplate;

#create and call parser
our $cltParser;
$cltParser = Parse::RecDescent->new($cltGrammar);
$cltParser->STARTRULE("@llvmLines") or die "clt-Parser start rule failed!"; 

#createTopAndMain() called separately as they have no
#equivalent in LLVM-IR
#can only work if lin size available (why not default to some value?)
createTopAndMain() if (defined $main::linSize);
print("OLT:: Parse llvm-IR and generate Tytra-IR string: ok\n");


##----------
## write tir
##----------
my $fhTir;
open ($fhTir, "> $outputFileTir") || die "problem opening $outputFileTir\n";

#put time stamp
my $timeStamp   = localtime(time);
$outTirBuff = ";-- Generation time stamp :: $timeStamp\n".$outTirBuff;

#write created string buffer to TIR file
print $fhTir $outTirBuff;
#foreach (@llvmLines) { 
#   print $fhTir $_ . "\n";        
#}
close $fhTir;
print("OLT:: Write  Tytra-IR to file: ok\n");              

#post
#-----
my $logFilename = "llvmTokens.log";
  open(my $outfh, '>', "$logFilename")
    or die "Could not open file '$logFilename' $!";
print $outfh Dumper(\%cltCode); 

print("\n------ TLUT DUMP -------\n");
print Dumper(\%tlut);
print("------ TLUT DUMP END---\n\n");


print("\n------ globalChannels DUMP -------\n");
print Dumper(\%globalChannels);
print("------ globalChannels DUMP END---\n\n");


##----------------------------
## call TYBEC on generated TIR
##----------------------------
if ($callTybec) {
  print("OLT:: Now calling TYBEC on the generated TIR: outputBuildDir/$outputFileTir\n\n\n"); 
  # --clt paramter tells tybec it has been called by this tool
  system("tybec.pl --clt --i $outputFileTir --g");
}  



#--------------------------------------------------------------
# lookupTlut
# Lookup the Translation LUT to see if variable replacement needed
#otherwise, return input as-is
#--------------------------------------------------------------
sub lookupTlut{
  my $func  = shift;
  my $luval = shift;
  #lookup recursively, until you find a value that is not in the table
  #which means this is the identifier to use
  if (exists $tlut{$func}{$luval}) {return lookupTlut($func, $tlut{$func}{$luval});}
  else                             {return $luval;}
}


#--------------------------------------------------------------
# createMain
#--------------------------------------------------------------
sub createTopAndMain{
  print("OLT:: Generating top and main with all default global arrays and linear sizes = $main::linSize\n");
  
  my $strTop          = '';
  my $strTopFunCalls  = '';
  my $strTopFunArgs   = '';

  my $strMain = '';
  
  $strTop .= "\n;-- ------------------\n"
          .  ";-- kernelTop\n"
          .  ";-- ------------------\n"
          .  "define void \@kernelTop  (\n"
          ;
  

  $strMain .= "\n;-- ------------------\n"
           .  ";--  MAIN\n"
           .  ";-- ------------------\n"
           .  "\n#define NLinear $main::linSize\n\n"
           .  "define void \@main () {\n"
           ;
  
  #find the arguments amongst all (non-stub) functions
  #that point to global memory

  my $gmemsBuff   ='';
  my $streamsBuff ='';
  my $callTop     = "\ncall \@kernelTop (\n";

  foreach my $func ( keys %cltCode) {
    #if function is stub, move on to next function
    next if ($cltCode{$func}{cat} eq 'stub');
    
    #call function in kernelTop
    $strTopFunCalls .= "call \@$func (\n";

    #loop through all args in func
    foreach my $arg ( keys %{$cltCode{$func}{args}}) {
      my $cat  = $cltCode{$func}{args}{$arg}{cat};
      my $type = $cltCode{$func}{args}{$arg}{type};
      my $dir  = $cltCode{$func}{args}{$arg}{dir};
      $type =~ s/\*//; #remove pointer * if there, not relevant in TIR

      $strTopFunCalls .= "\t$type \%$arg,\n";
      
      #global mem arguments have different effect on gen code
      if ($cat eq 'gmem') {
        
        #kernel tops argument list
        $strTopFunArgs .= "\t$type \%$arg,\n";

        #list of gmem buffers in main
        $gmemsBuff     .= "\t\%$arg = alloca [NLinear x $type], addrspace(1) \n";

        #list of stream objects in main
        if($dir eq 'input') {
          $streamsBuff.= "\n\t\%$arg"."_stream = streamread $type, $type* \%$arg\n"
        }
        else {
          $streamsBuff.= "\n\t streamwrite $type \%$arg"."_stream, $type* \%$arg\n"
        }                                 
        #this part is common whether in or our
        $streamsBuff  .= "\t, !tir.stream.type   !stream1d  \n"
                      .  "\t, !tir.stream.size   !NLinear   \n"
                      .  "\t, !tir.stream.saddr  !0         \n"
                      .  "\t, !tir.stream.stride !1         \n"
                      ;

        #arguments to kernelTop when calling it in main
        $callTop    .= "\t$type \%$arg"."_stream,\n";
      }#if
    }#foreach arg
    #close call to function
    $strTopFunCalls .= ")\n\n";
  }#foreach func

  #close strings
  $strTopFunArgs  .= ") pipe {\n\n";
  $callTop        .= ")\n";
  
  #complete the string for Kernel top
  $strTop .= $strTopFunArgs;
  $strTop .= $strTopFunCalls;
  $strTop .= "\tret void\n}\n";

  #complete string for main
  $strMain  .= $gmemsBuff;
  $strMain  .= $streamsBuff;
  $strMain  .= $callTop;
  $strMain  .= "\tret void\n}\n";

  #copy strings to mother string
  $outTirBuff .= $strTop;
  $outTirBuff .= $strMain;

}#()

#      my $aName = $cltCode{$func}{args}{$key}{name};
#      my $aType = $cltCode{$func}{args}{$key}{type};
#      my $aDir  = $cltCode{$func}{args}{$key}{dir} ;
#      $aType =~ s/\*//;
#        #remove pointer * if there, not relevant in TIR
#  
#        $gmemsBuff  .= "\t\%$aName = alloca [NLinear x $aType], addrspace(1) \n";
#        if($aDir eq 'in') {
#          $streamsBuff.= "\t\%$aName"."_stream = streamread $aType, $aType* \%$aName\n"
#                       . "\t, !tir.stream.type   !stream1d  \n"
#                       . "\t, !tir.stream.size   !NLinear   \n"
#                       . "\t, !tir.stream.saddr  !0         \n"
#                       . "\t, !tir.stream.stride !1         \n"
#                       ;
#        }
#        else {
#          $streamsBuff.= "\t streamwrite $aType \%$aName"."_stream, $aType* \%$aName\n"
#                       . "\t, !tir.stream.type   !stream1d  \n"
#                       . "\t, !tir.stream.size   !NLinear   \n"
#                       . "\t, !tir.stream.saddr  !0         \n"
#                       . "\t, !tir.stream.stride !1         \n"
#                       ;
#        }                                 
#      $args2Top  .= "\t $aType \%$aName"."_stream\t,\n"
#    }
#
#  $main::outTirBuff .= $gmemsBuff."\n";
#  $main::outTirBuff .= $streamsBuff."\n";
#  $main::outTirBuff .= "call \@$func (\n"
#                     . $args2Top
#                     . ")\n"
#                     ;
#  
#  #wrap up main
#  $main::outTirBuff .= "\tret void\n}\n";
#}#()


