#!/usr/bin/env nextflow
//
//  DO NOT EDIT FROM HERE!! - Unless you brave like King Shaka of course!
/*  ======================================================================================================
 *  HELP MENU
 *  ======================================================================================================
 */
if (params.help) {
    log.info ''
    log.info "===================================="
    log.info "         nf-rnaSeqMetagen v0.1        "
    log.info "===================================="
    log.info ''
    log.info 'USAGE: '
    log.info 'nextflow run main.nf --data /path/to/data --out /path/to/output --db /path/to/kraken-db --taxonomy /path/to/taxonomy --genome /path/to/genome.fa --index /path/to/STARIndex --bind /path/to/bind1;/path/to/bind2'
    log.info ''
    log.info 'HELP: '
    log.info 'nextflow run main.nf --help'
    log.info ''
    log.info 'MANDATORY ARGUEMENTS:'
    log.info '    --data     FOLDER    Path to where the input data is located (fastq | fq)'
    log.info '    --out      FOLDER    Path to where the output should be directed (will be created if it does not exist).'
    log.info '    --db       FOLDER    Path to where the Kraken database is installed'
    log.info '    --taxonomy FOLDER    Path to where the taxonomy database is installed'
    log.info '    --genome   FILE      The whole genome sequence (fasta | fa | fna)'
    log.info '    --index    FOLDER    Path to where the STAR index files are locaded'
    log.info '    --bind     FOLDER(S) Paths to be passed onto the singularity image'
    log.info ''
    log.info "====================================\n"
    exit 1
}
//
//
/*  ======================================================================================================
 *  CHECK ALL USER INPUTS
 *  ======================================================================================================
 */
if(params.data == null) {
    exit 1, "\nPlease enter a directory with input FASTQ/FASTQ.GZ files."
} else{
    data_path = file(params.data, type: 'dir')  // Path to where the input data is located (where fastq files are located).
}

if(params.out == null) {
    params.out = "${baseDir}/results_nf-rnaSeqCount"
} else{
    out_path = file(params.out, type: 'dir')   // Path to where the output should be directed.
}

if(params.db== null) {
    exit 1, "Please provide the KRAKEN database directory."
} else{
    genome = file(params.db, type: 'dir')  // The KRAKEN database.
}

if(params.taxonomy == null) {
    exit 1, "Please provide the taxonomy database."
} else{
    genome = file(params.taxonomy, type: 'dir')  // The taxonomy database file.
}

if(params.genome == null) {
    exit 1, "Please provide a FASTA sequence of the reference genome."
} else{
    genome = file(params.genome, type: 'file')  // The whole genome sequence.
}

if(params.index == null) {
    exit 1, "Please provide a STAR index."
} else{
    index = file(params.index, type: 'dir')  // Path to where the STAR index files are locaded.
}
//
//
/*  ======================================================================================================
 *  RUN INFO
 *  ======================================================================================================
 */
log.info "===================================="
log.info "           nf-rnaSeqCount           "
log.info "===================================="
log.info "Input data          : ${data_path}"
log.info "Output path         : ${out_path}"
log.info "Kraken database     : ${db}"
log.info "Taxonomy database   : ${taxonomy}"
log.info "Genome              : ${genome}"
log.info "Genome Index (STAR) : ${index}"
log.info "Paths to bind       : ${bind}"
log.info "====================================\n"
//
//
/*  ======================================================================================================
 *  PIPELINE START
 *  ======================================================================================================
 */
// Create output directory
out_path.mkdir()

// Get input reads
read_pair = Channel.fromFilePairs("${data_path}/*R[1,2].fastq", type: 'file') 
.ifEmpty { error "ERROR - Data input: \nOooops... Cannot find any '.fastq' or '.fq' files in ${data_path}. Please specify a folder with '.fastq' or '.fq' files."}

// 1.  Align reads to reference genome
process runSTAR_process {
    cpus 6
    memory '40 GB'
    time '10h'
    scratch '$HOME/tmp'
    tag { sample }
    publishDir "$out_path/${sample}", mode: 'copy', overwrite: false
    
    input:
    set sample, file(reads) from read_pair
    
    output:
    set sample, file("${sample}_*") into star_results
    set sample, file("${sample}_Unmapped*") into unmapped_kraken, unmapped_trinity
    
    """	
    STAR --runMode alignReads \
       --genomeDir ${index} \
       --readFilesIn ${reads.get(0)} ${reads.get(1)} \
       --runThreadN 5 \
       --outSAMtype BAM SortedByCoordinate \
       --outReadsUnmapped Fastx \
       --outFileNamePrefix ${sample}_
       
    sed -i 's|\\s.[0-9]\$|\\/1|g' ${sample}_Unmapped.out.mate1 
    sed -i 's|\\s.[0-9]\$|\\/2|g' ${sample}_Unmapped.out.mate2

    """ 
}

// 2. Run KRAKEN to classify the raw reads that aren't mapped to the reference genome.
process runKrakenClassifyReads_process {
    cpus 6
    memory '150 GB'
    time '10h'
    scratch '$HOME/tmp'
    tag { sample }
    publishDir "$out_path/${sample}", mode: 'copy', overwrite: false
    
    input:
    set sample, file(reads) from unmapped_kraken
    
    output:
    set sample, file("${sample}_reads.krak") into kraken_classified_reads 
    
    """	
    /bin/hostname
    kraken --db ${db} \
        --fastq-input \
        --paired ${reads.get(0)} ${reads.get(1)} \
        --threads 5 \
        --output ${sample}_reads.krak
    """ 
}

// 3. Assemble the reads into longer contigs/sequences for classification.
process runTrinityAssemble_process {
     cpus 6
     memory '150 GB'
     time '50h'
    scratch '$HOME/tmp'
     tag { sample }
     publishDir "$out_path/${sample}", mode: 'copy', overwrite: false
    
     input:
     set sample, file(reads) from unmapped_trinity
    
     output:
     set sample, "trinity_${sample}/Trinity.fasta" into trinity_assembled_reads

     """
     Trinity --seqType fq \
        --max_memory 150G \
        --left ${reads.get(0)} --right ${reads.get(1)} \
        --SS_lib_type RF \
        --CPU 5 \
        --output  trinity_${sample}
     """
 }

// 4. Run KRAKEN to classify the assembled FASTA sequences.
process runKrakenClassifyFasta_process{
    cpus 6
    memory '150 GB'
    time '10h'
    scratch '$HOME/tmp'
    tag { sample }
    publishDir "$out_path/${sample}", mode: 'copy', overwrite: false

    input:
    set sample, file(fasta) from trinity_assembled_reads

    output:
    set sample, file("${sample}_fasta.krak") into kraken_classified_fasta 

    """	
    kraken --db ${db} \
        --fasta-input ${fasta} \
        --threads 5 \
        --output ${sample}_fasta.krak
    """ 
}

// For each sample, create a list with [ SAMPLE_NAME, READ, FASTA ] by merging the classified outputs (reads and fasta) from KRAKEN 
all_classified = kraken_classified_reads.merge( kraken_classified_fasta ) { listA, listB -> [ listA[0], [listA[1], listB[1]] ] }

// 5. Create that pretty KRONA report for all samples (reads and fasta)
process runKronareport{
    cpus 8
    memory '5 GB'
    time '10h'
    scratch '$HOME/tmp'
    tag { sample }
    publishDir "$out_path/${sample}", mode: 'copy', overwrite: false
    
    input:
    set sample, file(kraken) from all_classified
    
    output:
    set sample, file("*") into html

    """
    function createChart {
        cut -f 2,3 \$1 > \$(sed 's/.krak/.kron/' <<< "\$1")
        ktImportTaxonomy \$(sed 's/.krak/.kron/' <<< "\$1") \
            -tax ${taxonomy} \
            -o \$(sed 's/.krak/.html/' <<< "\$1")
        }
    createChart ${kraken.get(0)}
    createChart ${kraken.get(1)}
    """
}

// 6a. Collect files for STAR QC
star_results.collectFile () { item -> [ 'qc_star.txt', "${item.get(1).find { it =~ 'Log.final.out' } }" + ' ' ] }
.set { qc_star }

// 6. Get QC for STAR, HTSeqCounts and featureCounts
process runMultiQC_process {
    cpus 1
    memory '5 GB'
    time '10h'
    scratch '$HOME/tmp'
    tag { sample }
    publishDir "$out_path/report_QC", mode: 'copy', overwrite: false

    input:
    file(star) from qc_star

    output:
    file('*') into multiQC

    """
    multiqc `< ${star}` --force
    """
}
//
/*  ======================================================================================================
 *  WORKFLOW SUMMARY 
 *  ======================================================================================================
 */
workflow.onComplete {
    println "===================================="
    println "Pipeline execution summary:"
    println "===================================="
    println "Execution command   : ${workflow.commandLine}"
    println "Execution name      : ${workflow.runName}"
    println "Workflow start      : ${workflow.start}"
    println "Workflow end        : ${workflow.complete}"
    println "Workflow duration   : ${workflow.duration}"
    println "Workflow completed? : ${workflow.success}"
    println "Work directory      : ${workflow.workDir}"
    println "Project directory   : ${workflow.projectDir}"
    println "Execution directory : ${workflow.launchDir}"
    println "Configuration files : ${workflow.configFiles}"
    println "Workflow containers : ${workflow.container}"
    println "exit status : ${workflow.exitStatus}"
    println "Error report: ${workflow.errorReport ?: '-'}"
    println "===================================="
}

workflow.onError {
    println "Oohhh DANG IT!!... Pipeline execution stopped with the following message: ${workflow.errorMessage}"
}
//======================================================================================================
