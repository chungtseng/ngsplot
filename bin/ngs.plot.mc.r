#!/usr/bin/env Rscript
#
# Program: ngs.plot.r
# Purpose: Plot sequencing coverages at different genomic regions.
#          Allow overlaying various coverages with gene lists.
# Arguments: coverage file, region to plot, title, output basename.
#            user can also supply a text file describing the interaction between
#            coveage files and gene lists; or a customized region list in BED
#            format.
#
# -- by Li Shen, MSSM
#    Nov 2011.
#

# Deal with command line arguments.
cmd.help <- function(){
	cat("\nUsage: ngs.plot.r -C cov_file -R region_2_plot -O out_base_name [-FI forbid_image] [-F reg_further_info] [-D database_2_use] [-T title] [-G gene_list] [-I interval_size] [-L flanking_size] [-N flanking_factor] [-S random_sample_rate] [-A smooth_function_radius] [-M smooth_method] [-H shaded_area] [-E weigh_genelen] [-P cores_number]\n")
	cat("\n")
	cat("-C     Coverage file to plot or for multiplot, a *.txt file(see multiplot.example.txt)\n")
	cat("-R     Genomic region, can be: tss, tes, genebody, exon, cgi or customized *.bed file\n")
	cat("-O     Output basename. Two files will be generated: png image and text file\n")
	cat("-FI    Forbid image output if set to 1(default=0)\n")
	cat("-F     If you select genebody, exon or cgi, further information can be provided for specific regions to plot:\n")
	cat("         for genebody: chipseq(default), rnaseq.\n")
	cat("         for exon: canonical(default), variant, promoter, polyA, altAcceptor, altDonor, altBoth.\n")
	cat("         for cgi, choose from one of seven categories: Genebody, Genedesert, OtherIntergenic, \n")
	cat("           Pericentromere, Promoter1k, Promoter3k, ProximalPromoter(default).\n")
	cat("-D     Supported gene database: refseq, ensembl(optional, default=refseq)\n")
	cat("-T     Image title(optional)\n")
	cat("-G     Gene list(optional)\n")
	cat("-I     Interval size(optional, default varies by type: genebody=3000;exon=250;cgi=500\n")
	cat("-L     Flanking region size(optional, default varies by type: tss,tes,genebody=1000;exon=500;cgi=500)\n")
	cat("-N     Specify flanking region as a multiple(or fraction) of interval size, can be less than 1. In this case, flanking region has floating size with interval size.\n")
	cat("-S     Randomly sample the genome for plot, must be:(0, 1] (default=1, i.e. whole genome)\n")
	cat("-A     Radius used by smooth function, must be:[0, 1)(optional, default=0). Larger value means smoother plot.\n")
	cat("         suggested value for -A is <= 0.05\n")
	cat("-M     Smooth method, choose from: mean, median(default=mean)\n")
	cat("-H     Use shaded area for coverage plots instead of curves. set it as [0, 1) for degree of opacity (default=0, i.e. off). suggested value: <0.5\n")
	cat("-E     By default, do NOT calculate weighted coverage for splined curves using gene length. However, this can be useful, e.g. when comparing enrichment of a histone mark under two conditions. Can be turned on by setting -E to 1.\n")
	cat("-P     Number of the cores to be used. By default, only one core is used. Set it as 0, then all detected cores are used.\n")
	cat("\n")
}

args <- commandArgs(T)
progpath <- Sys.getenv('NGSPLOT')
if(progpath == ""){
	stop("Set environment variable NGSPLOT before run the program. See README for details.\n")
}else{
	if(substr(progpath, nchar(progpath), nchar(progpath)) != '/'){	# add trailing slash.
		progpath <- paste(progpath, '/', sep='')
	}
}
source(paste(progpath, 'lib/parse.args.r', sep=''))
source(paste(progpath, 'lib/plotmat.r', sep=''))
args.tbl <- parse.args(args, c('-C', '-R', '-O'))
if(is.null(args.tbl)){
	cmd.help()
	stop('Error in parsing command line arguments. Stop.\n')
}
covfile <- args.tbl['-C']
reg2plot <- args.tbl['-R']
basename <- args.tbl['-O']

# Determine coverage-title-genelist relationship.
if(length(grep('.txt$', covfile))>0){
	ctg.tbl <- read.table(covfile, sep="\t", col.names=c('cov','glist','title'), as.is=T)
}else{
	if('-G' %in% names(args.tbl)){
		glist <- args.tbl['-G']
	}else{
		glist <- '-1'
	}
	if('-T' %in% names(args.tbl)){
		title <- args.tbl['-T']
	}else{
		title <- 'Noname'
	}
	ctg.tbl <- data.frame(cov=covfile, glist=glist, title=title, stringsAsFactors=F)
}

# Collapse coverage files to speed up loading.
cov.u <- unique(ctg.tbl$cov)

# Load the 1st coverage. The genome name is then used for loading gene models.
cov2load <- cov.u[1]
load(cov2load)	# genome, nreads, read.coveage, read.coveage.n
if(genome == 'mm9'){	# load genome: refseq, ensembl, cgiUCSC
	load(paste(progpath, 'database/mm9.RData', sep=''))
}else if(genome == 'hg19'){
	load(paste(progpath, 'database/hg19.RData', sep=''))
}else if(genome == 'rn4'){
	load(paste(progpath, 'database/rn4.RData', sep=''))
}else{
	stop(paste('Unsupported genome: ', genome, '. Stop.\n', sep=''))
}

## Figuring out configuration for various data structures. ##
if('-FI' %in% names(args.tbl)){	# image output forbidden tag.
	stopifnot(as.integer(args.tbl['-FI']) >= 0)
	fi_tag <- as.integer(args.tbl['-FI'])
}else{
	fi_tag <- as.integer(0)
}

if('-D' %in% names(args.tbl)){	# database.
	database <- as.character(args.tbl['-D'])
	if(database == 'refseq'){	# choose database.
		genemodel <- refseq
	}else if(database == 'ensembl'){
		genemodel <- ensembl
	}else{
		stop('Unsupported database.')
	}
}else{
	genemodel <- refseq
}

if(reg2plot == 'tss' || reg2plot == 'tes'){	# determine the set of genomic coordinates.
	genome.coord <- genemodel$genebody
}else if(reg2plot == 'genebody'){
	if('-F' %in% names(args.tbl)){
		finfo <- as.character(args.tbl['-F'])
		gb.allowed <- c('chipseq', 'rnaseq')
		stopifnot(finfo %in% gb.allowed)
	}else{
		finfo <- 'chipseq'
	}
	genome.coord <- genemodel$genebody
}else if(reg2plot == 'exon'){
	if('-F' %in% names(args.tbl)){
		finfo <- as.character(args.tbl['-F'])
		exon.allowed <- c('canonical', 'variant', 'promoter', 'polyA', 'altAcceptor', 'altDonor', 'altBoth')
		stopifnot(finfo %in% exon.allowed)
	}else{
		finfo <- 'canonical'
	}
	genome.coord <- genemodel$exon
}else if(reg2plot == 'cgi'){
	if('-F' %in% names(args.tbl)){
		finfo <- as.character(args.tbl['-F'])
		cgi.allowed <- c("Genebody", "Genedesert", "OtherIntergenic", "Pericentromere", "Promoter1k", "Promoter3k", "ProximalPromoter")
		stopifnot(finfo %in% cgi.allowed)
	}else{
		finfo <- 'ProximalPromoter'
	}
	genome.coord <- genemodel$cgi
}else if(length(grep('.bed$', reg2plot))>0){
	bed.coord <- read.table(reg2plot, sep="\t")
	if(ncol(bed.coord)==3){
		genome.coord <- data.frame(chrom=bed.coord[, 1], start=bed.coord[, 2]+1, end=bed.coord[, 3], gid=NA, gname='N', tid='N', strand='+', byname.uniq=T, bygid.uniq=NA)
	}else if(ncol(bed.coord)==6){
		genome.coord <- data.frame(chrom=bed.coord[, 1], start=bed.coord[, 2]+1, end=bed.coord[, 3], gid=NA, gname=bed.coord[, 4], tid=bed.coord[, 5], strand=bed.coord[, 6], byname.uniq=T, bygid.uniq=NA)
	}else{
		stop('Input must be BED3 or BED6 format!')
	}
	reg2plot <- 'bed'	# rename for information retrieval
}
if(reg2plot == 'genebody' && finfo == 'rnaseq'){
	rnaseq.gb <- T
}else{
	rnaseq.gb <- F
}
if(reg2plot == 'exon' || reg2plot == 'cgi'){	# subset specific region.
	genome.coord <- genome.coord[[finfo]]
}

if('-I' %in% names(args.tbl)){	# interval region size.
	stopifnot(as.integer(args.tbl['-I']) > 0)
	intsize <- args.tbl['-I']
}else{
	int.tbl <- c(3000,250,500,1000)
	names(int.tbl) <- c('genebody','exon','cgi','bed')
	intsize <- int.tbl[reg2plot]
}
if(reg2plot == 'tss' || reg2plot == 'tes'){
	intsize <- 1
}
intsize <- as.integer(intsize)

if('-L' %in% names(args.tbl)){	# flanking region size.
	stopifnot(as.integer(args.tbl['-L']) >= 0)
	flanksize <- args.tbl['-L']
}else{
	flank.tbl <- c(1000,1000,1000,500,500,1000)
	names(flank.tbl) <- c('tss','tes','genebody','exon','cgi','bed')
	flanksize <- flank.tbl[reg2plot]
}
flanksize <- as.integer(flanksize)

if('-N' %in% names(args.tbl) && !('-L' %in% names(args.tbl))){	# flanking size factor.
	stopifnot(as.numeric(args.tbl['-N']) >= 0)
	flankfactor <- as.numeric(args.tbl['-N'])
	flanksize <- floor(intsize*flankfactor)
}else{
	flankfactor <- 0.0
}
if(rnaseq.gb){	# RNA-seq plotting.
	flanksize <- 0
}

if('-S' %in% names(args.tbl)){	# random sampling rate.
	samprate <- as.numeric(args.tbl['-S'])
	stopifnot(samprate > 0 && samprate <= 1)
	recs <- which(genome.coord$byname.uniq)	# records to sample from.
	if(samprate < 1){	# random sample indices.
		samp.i <- sample(recs, floor(samprate*length(recs)))
	}
}else{
	samprate <- 1.0
}

if('-H' %in% names(args.tbl)){	# shaded area alpha.
	shade.alp <- as.numeric(args.tbl['-H'])
	stopifnot(shade.alp >= 0 || shade.alp < 1)
}else{
	shade.alp <- 0
}

if('-A' %in% names(args.tbl)){	# smooth function radius.
	smooth.radius <- as.numeric(args.tbl['-A'])
	stopifnot(smooth.radius >= 0 && smooth.radius < 1)
}else{
	smooth.radius <- .0
}

if('-M' %in% names(args.tbl)){	# smoothing method.
	smooth.method <- as.character(args.tbl['-M'])
	stopifnot(smooth.method == 'mean' || smooth.method == 'median')
}else{
	smooth.method <- 'mean'
}

if('-E' %in% names(args.tbl)){	# weighted coverage.
	stopifnot(as.integer(args.tbl['-E']) >= 0)
	weight.genlen <- as.integer(args.tbl['-E'])
}else{
	weight.genlen <- as.integer(0)
}

if('-P' %in% names(args.tbl)){	# set cores number.
	stopifnot(as.integer(args.tbl['-P']) >= 0)
	cores.number <- as.integer(args.tbl['-P'])
}else{
	cores.number <- as.integer(1)
}
# Create the matrix to store plotting data.
if(rnaseq.gb){
	regcovMat <- matrix(0, nrow=intsize, ncol=nrow(ctg.tbl))
}else{
	regcovMat <- matrix(0, nrow=2*flanksize + intsize, ncol=nrow(ctg.tbl))
}
colnames(regcovMat) <- ctg.tbl$title

## End configuration ##


##### Start the plotting routines ####
# Load required libraries.
require(ShortRead)||{source("http://bioconductor.org/biocLite.R");biocLite(ShortRead);TRUE}
require(BSgenome)||{source("http://bioconductor.org/biocLite.R");biocLite(BSgenome);TRUE}
require(doMC)

# Function to check if the range exceeds coverage vector boundaries.
checkBound <- function(start, end, range, chrlen){
	if(end + range > chrlen ||
		start - range < 1)
		return(FALSE)	# out of boundary.
	else
		return(TRUE)
}

# Extract and interpolate coverage vector from a genomic region with 3 sections:
# 5' raw region, variable middle region and 3' raw region.
extrCov3Sec <- function(chrcov, start, end, ninterp, flanking, strand, weight){
	left.cov <- as.vector(seqselect(chrcov, start - flanking, start - 1))
	right.cov <- as.vector(seqselect(chrcov, end + 1, end + flanking))
	middle.cov <- as.vector(seqselect(chrcov, start, end))
	middle.cov.intp <- spline(1:length(middle.cov), middle.cov, n=ninterp)$y
	if(weight){
		middle.cov.intp <- (length(middle.cov) / ninterp) * middle.cov.intp
	}
	if(strand == '+'){
		return(c(left.cov, middle.cov.intp, right.cov))
	}else{
		return(rev(c(left.cov, middle.cov.intp, right.cov)))
	}
}

# Extract and interpolate coverage vector from a genomic region.
extrCovSec <- function(chrcov, start, end, ninterp, flanking, strand, weight){
	cov <- as.vector(seqselect(chrcov, start - flanking, end + flanking))
	cov.intp <- spline(1:length(cov), cov, n=ninterp)$y
	if(weight){
		cov.intp <- (length(cov) / ninterp) * cov.intp
	}
	if(strand == '+'){
		return(cov.intp)
	}else{
		return(rev(cov.intp))
	}
}


# Extract and concatenate coverages for a mRNA using exon model. Then do interpolation.
extrCovExons <- function(chrcov, ranges, ninterp, strand, weight){
	cov <- as.vector(seqselect(chrcov, ranges))
	cov.intp <- spline(1:length(cov), cov, n=ninterp)$y
	if(weight){
		cov.intp <- (length(cov) / ninterp) * cov.intp
	}
	if(strand == '+'){
		return(cov.intp)
	}else{
		return(rev(cov.intp))
	}
}

# Extract coverage vector from a genomic region with a middle point and symmetric flanking regions.
extrCovMidp <- function(chrcov, midp, flanking, strand){
	res.cov <- as.vector(seqselect(chrcov, midp - flanking, midp + flanking))
	if(strand == '+'){
		return(res.cov)
	}else{
		return(rev(res.cov))
	}
}

do.par.cov <- function(k, plot.coord, read.coverage.n, rnaseq.gb,
                     flankfactor, reg2plot, genemodel, weight.genlen,
                     intsize, old_flanksize, flanksize){
	chrom <- as.character(plot.coord[k, ]$chrom)
	if(!chrom %in% names(read.coverage.n)) return(NULL)
	strand <- plot.coord[k, ]$strand
	if(flankfactor > 0 && !rnaseq.gb){
		flanksize <- floor((plot.coord[k, ]$end - plot.coord[k, ]$start + 1)*flankfactor)
	}
	if((reg2plot == 'tss' && strand == '+') || (reg2plot == 'tes' && strand == '-')){
		if(!checkBound(plot.coord[k, ]$start, plot.coord[k, ]$start, flanksize, length(read.coverage.n[[chrom]])))
			return(NULL)
		result <- extrCovMidp(read.coverage.n[[chrom]], plot.coord[k, ]$start, flanksize, strand)
	}else if(reg2plot == 'tss' && strand == '-' || reg2plot == 'tes' && strand == '+'){
		if(!checkBound(plot.coord[k, ]$end, plot.coord[k, ]$end, flanksize, length(read.coverage.n[[chrom]])))
			return(NULL)
		result <- extrCovMidp(read.coverage.n[[chrom]], plot.coord[k, ]$end, flanksize, strand)
	}else{
		if(!checkBound(plot.coord[k, ]$start, plot.coord[k, ]$end, flanksize, length(read.coverage.n[[chrom]])))
			return(NULL)
		if(rnaseq.gb){	# RNA-seq plot using exon model.
			exon.ranges <- genemodel$exonmodel[[plot.coord$tid[k]]]$ranges
			result <- extrCovExons(read.coverage.n[[chrom]], exon.ranges, intsize, strand, weight.genlen)
		}else{
			if(flankfactor > 0){	# one section coverage.
				result <- extrCovSec(read.coverage.n[[chrom]], plot.coord[k, ]$start, plot.coord[k, ]$end, intsize+2*old_flanksize, flanksize, strand, weight.genlen)
			}else{	# three section coverage.
				result <- extrCov3Sec(read.coverage.n[[chrom]], plot.coord[k, ]$start, plot.coord[k, ]$end, intsize, flanksize, strand, weight.genlen)
			}
		}
	}
	result
}

i <- 1	# index for unique coverage files.
old_flanksize <- flanksize
if(cores.number == 0){
	registerDoMC()
} else {
	registerDoMC(cores.number)
}
while(i <= length(cov.u)){	# go through all unique coverage files.
	same.cov.r <- which(ctg.tbl$cov == cov2load)
	for(j in 1:length(same.cov.r)) {	# go through all
                                        # gene lists associated with
                                        # each coverage.
		r <- same.cov.r[j]	# row number.
		lname <- ctg.tbl$glist[r]	# gene list name: used to subset
                                     # the genome.
		if(lname == '-1'){	# use genome as gene list.
			if(samprate < 1){
				plot.coord <- genome.coord[samp.i, ]
			}else{
				plot.coord <- subset(genome.coord, byname.uniq)
			}
		}else{	# read gene list from text file.
			gene.list <- read.table(lname, as.is=T)$V1
			subset.idx <- c(which(genome.coord$gname %in% gene.list & genome.coord$byname.uniq),
				which(genome.coord$tid %in% gene.list))
			if(!all(is.na(genome.coord$gid))){
				subset.idx <- c(subset.idx, which(genome.coord$gid %in% gene.list & genome.coord$bygid.uniq))
			}
			plot.coord <- genome.coord[subset.idx, ]
		}
		nplot <- 0	# book-keep the number of regions drawn(for
                      # averaging).
		fin.result <- foreach(k=1:nrow(plot.coord)) %dopar% {	# go through all
                                        				# regions.
          		do.par.cov(k, plot.coord, read.coverage.n, rnaseq.gb,
				flankfactor, reg2plot, genemodel, weight.genlen,
				intsize, old_flanksize, flanksize)
		}
		for (result in fin.result){
			if (!is.null(result)){
				regcovMat[,r] <- regcovMat[,r] + result
				nplot <- nplot + 1
			}
		}
		if(nplot > 0)
			regcovMat[, r] <- regcovMat[, r] / nplot
	}
	i <- i+1
	if(i <= length(cov.u)){	# load a new coverage file.
		cov2load <- cov.u[i]
		load(cov2load)
	}
}
flanksize <- old_flanksize	# recover the original flanksize.
# Smooth plot if specified.
if(smooth.radius > 0){
	source(paste(progpath, 'lib/smoothplot.r', sep=''))
	regcovMat <- smoothplot(regcovMat, smooth.radius, smooth.method)
}

default.width <- 1000
default.height <- 900
if(!fi_tag){
	out.png <- paste(basename, '.png', sep='')
	# Plot the matrix!
	plotmat(out.png, default.width, default.height, 24, 
		reg2plot, flanksize, intsize, flankfactor, shade.alp, rnaseq.gb,
		regcovMat, ctg.tbl$title)
}

# Save plotting data to a text file.
out.txt <- paste(basename, '.txt', sep='')
out.header <- c('#Do NOT change the following lines if you want to re-draw the image with replot.r! If you change the matrix values, cut and paste the commented lines into your new file and run replot.r.',
	paste('#reg2plot:', reg2plot, sep=''),
	paste('#flanksize:', flanksize, sep=''),
	paste('#intsize:', intsize, sep=''),
	paste('#flankfactor:', flankfactor, sep=''),
	paste('#shade.alp:', shade.alp, sep=''),
	paste('#rnaseq.gb:', rnaseq.gb, sep=''),
	paste('#width:', default.width, sep=''),
	paste('#height:', default.height, sep=''))
writeLines(out.header, out.txt)
write.table(regcovMat, append=T, file=out.txt, row.names=F, sep="\t", quote=F)
