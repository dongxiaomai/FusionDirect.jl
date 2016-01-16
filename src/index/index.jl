const DNA2BIT = Dict('A'=>0, 'T'=>1, 'C'=>2, 'G'=>3)
const KMER = 16

"""
the position of a k-mer sequence is the position of its first base, normalized to the direction of strand +
this is why a kmer sequence and its reverse compelement has a position offset of KMER-1
for example
contig: AAAATTTTCCCCGGG[G]TCATGATTACCAACCAATACCGTGGGATGG
position of the first 16-mer AAAATTTTCCCCGGGG is: 1
position of reverse compelement of the first 16-mer, CCCCGGGGAAAATTTT is: 1+16-1 = 16, the position bracketed
"""
immutable Coord
    # of which contig, usually a chr, a gene, an exon or any sequence
    contig::Int16
    # offset in this contig
    pos::Int32
    # in which strand, 1 means +, -1 means -
    strand::Int16

    Coord(contig, pos, strand = 1) = new(Int16(contig), Int32(pos), Int16(strand))
end

# for debugging
function display_coords(coords::Array{Coord, 1})
    i = 0
    for coord in coords
        if valid(coord)
            print("(", coord.strand>0?"+":"-", coord.contig, ":", coord.pos, ")\t")
        elseif coord.contig == -1
            print("(duplicate)\t")
        elseif coord.contig == -2
            print("(unknown)\t")
        end
        i+=1
        if i%10 == 0
            print("\n")
        end
    end
    print("\n")
end

# generate a coord represents a kmer key collision
function dup_coord()
    return Coord(-1, 0)
end

# generate a coord represents a unknown key
function unknown_coord()
    return Coord(-2, 0)
end

# distance of two coords
function distance(c1::Coord, c2::Coord)
    if c1.contig != c2.contig || c1.strand != c2.strand
        return Inf
    else
        return c1.pos - c2.pos
    end
end

-(c1::Coord, c2::Coord) = distance(c1::Coord, c2::Coord)

is_dup(coord::Coord) = (coord.contig == -1)
is_unknown(coord::Coord) = (coord.contig == -2)
valid(coord::Coord) = (coord.contig >= 0)

typealias KmerCoord Dict{Int64, Coord}
typealias KmerCoordList Dict{Int64, Array{Coord, 1}}

function kmer2key(seq::Sequence)
    kmer2key(seq.seq)
end

# convert a kmer seq to a int64 key
function kmer2key(str::ASCIIString)
    str = uppercase(str)
    if contains(str, "N")
        return -1
    end
    key = 0
    for c in str
        key = key*4 + DNA2BIT[c]
    end
    return key
end

# add and index a kmer of a panel
function add_to_panel_index(kmer_coord::KmerCoord, seq::Sequence, coord::Coord)
    key = kmer2key(seq)
    if key in keys(kmer_coord)
        kmer_coord[key] = dup_coord()
        return false
    end
    kmer_coord[key] = coord
    return true
end


# add and index all kmers of a contig
function index_contig(kmer_coord::KmerCoord, contig_seq::Sequence, contig_number::Int)
    len = length(contig_seq)
    for i in 1:len-KMER+1
        seq = contig_seq[i:i+KMER-1]
        add_to_panel_index(kmer_coord, seq, Coord(contig_number, i, 1))
        add_to_panel_index(kmer_coord, ~seq, Coord(contig_number, i+KMER-1, -1))
    end
end

# ref_path is a folder contains fasta files by chromosomes
# like chr1.fa, chr2.fa ...
function make_panel_index(ref_path::AbstractString, bed_file::AbstractString)
    ref = load_reference(ref_path)
    panel_kmer_coord = KmerCoord()
    io = open(bed_file)
    bed_file = readall(io)
    lines = split(bed_file, '\n')
    contig_number = 0
    panel = Dict{Int16, Dict{}}()
    panel_seq = Dict{Int16, Sequence}()
    chr_bed = Dict{ASCIIString, Array{Int}}()
    for line in lines
        line = rstrip(line, '\n')
        cols = split(line)
        if length(cols)<4
            continue
        end
        contig_number += 1
        chr = ASCIIString(cols[1])
        if (chr in keys(chr_bed))==false
            chr_bed[chr]=Array{Int,1}()
        end
        push!(chr_bed[chr], contig_number)
        from = parse(Int64, ASCIIString(cols[2]))
        to = parse(Int64, ASCIIString(cols[3]))
        contig_name = ASCIIString(cols[4])
        panel[contig_number] = Dict("chr"=>chr, "name"=>contig_name, "from"=>from, "to"=>to)
    end
    for (chr,contig_numbers) in chr_bed
        chr_file = ref_path * "/" * chr * ".fa"
        chr_seq = load_chr(chr_file, chr)
        if chr_seq==false
            error("cannot load data of chromosome $chr")
        end
        for contig_number in contig_numbers
            from = panel[contig_number]["from"]
            to = panel[contig_number]["to"]
            contig_seq = chr_seq[from:to]
            index_contig(panel_kmer_coord, contig_seq, contig_number)
            panel_seq[contig_number] = contig_seq
        end
    end
    ref_kmer_coords = make_kmer_coord_list(ref, panel_kmer_coord)
    return Dict("panel"=>panel, "seq"=>panel_seq, "kmer_coord"=>panel_kmer_coord, "ref_kmer_coords"=>ref_kmer_coords)
end

# make an index with the reference data and a panel
# for each kmer of the panel, create an array, and store the coordinations of same kmer
function make_kmer_coord_list(ref::Array{FastaRead, 1}, panel_kmer_coord::KmerCoord)
    ref_index = KmerCoordList()
    panel_keys = keys(panel_kmer_coord)
    total = 0
    for k in panel_keys
        ref_index[k]=Array{Coord, 1}()
    end

    # create parallel tasks
    tasks = []
    for chrid in 1:length(ref)
        chrseq = ref[chrid].sequence
        task = Dict("chrid"=>chrid, "chrseq"=>chrseq, "panel"=>panel_kmer_coord)
        push!(tasks, task)
    end
    if length(workers()) <= 1
        #addprocs()
    end

    # run parallel for indexing
    results = pmap(make_kmer_coord_list_chr, tasks)

    # merge the result index
    for k in panel_keys
        for result in results
            if haskey(result, k)
                append!(ref_index[k], result[k])
            end
        end
    end

    # destroy worker processes
    rmprocs(workers())

    return ref_index
end

# run in parallel
# make an index with a chromosome of the reference data and a panel
function make_kmer_coord_list_chr(task)
    chrid=task["chrid"]
    chrseq=task["chrseq"]
    panel_kmer_coord=task["panel"]
    ref_index = KmerCoordList()
    panel_keys = keys(panel_kmer_coord)
    total = 0
    len = length(chrseq)
    for i in 1:len-KMER+1
        if i%1000000 == 0
            println("$chrid:$i/$total")
        end
        seq = chrseq[i:i+KMER-1]
        key = kmer2key(seq)
        if key in panel_keys
            if !haskey(ref_index, key)
                ref_index[key]=Array{Coord, 1}()
            end
            push!(ref_index[key], Coord(Int16(chrid), i, 1))
            total+=1
        end
        key = kmer2key(~seq)
        if key in panel_keys
            if !haskey(ref_index, key)
                ref_index[key]=Array{Coord, 1}()
            end
            push!(ref_index[key], Coord(Int16(chrid), i+KMER-1, -1))
            total+=1
        end
    end
    return ref_index
end

function get_cache_path(ref_path::AbstractString, bed_file::AbstractString)
    ref_name = basename(ref_path) * "." * string(filesize(ref_path))
    bed_name = basename(bed_file) * "." * string(filesize(bed_file))
    cache_name = bed_name * "_" * ref_name * ".idx"
    cache_path = joinpath(dirname(bed_file), cache_name)
    return cache_path
end

function index_bed(ref_path::AbstractString, bed_file::AbstractString)
    cache_path = get_cache_path(ref_path, bed_file)
    # load the index from a cache file
    if isfile(cache_path) && isreadable(cache_path)
        io = open(cache_path)
        index = deserialize(io)
        return index
    else
        println("## index doesn't exist, indexing now, it may take several minutes to a few hours")
        println("## after the index is created, loading it will be very fast")
        index = make_panel_index(ref_path, bed_file)
        # save the index to a cache file
        io = open(cache_path, "w")
        serialize(io, index)
        return index
    end
end