needs 'PCR Libs/GradientPcrHelpers'

module GradientPcrRepresentation
	include GradientPcrHelpers

	# Object representation for an individual pcr reaction.
	# PcrOperation keeps track of all the necessary factors
	# for a pcr.
	class PcrOperation

		attr_reader :extension_time, :anneal_temp, :extension_group, :tanneal_group

		# make a brand new PcrOperation.
		#
		# @param opts [Hash]  initialization options
		# @option opts [Float] :extension_time  extension time for this pcr operation
		# @option opts [Float] :anneal_temp  the annealing temperature for this pcr operation
		# @option opts [Integer] :extension_group  a group id for this operation, shared with 
		# 							other pcr operations who could be run together in a reaction 
		# 							with the same extension time
		# @option opts [Integer] :tanneal_group  a group id for this operation, shared with 
		# 							other pcr operations who could be run together in a reaction 
		# 							with the same annealing temperature
		def initialize opts = {}
			@extension_time 	= opts[:extension_time]
			@anneal_temp 		= opts[:anneal_temp]
			@extension_group 	= opts[:extension_group]
			@tanneal_group 		= opts[:tanneal_group]
		end

		# get an exact copy of this pcr operation
		def clone
			PcrOperation.new({
				extension_time: 	@extension_time,
				anneal_temp: 		@anneal_temp,
				extension_group: 	@extension_group,
				tanneal_group: 		@tanneal_group
			})
		end

		def to_string 
			"extension_time: #{@extension_time} + \n anneal_temp: #{@anneal_temp} + \n extension_group: #{@extension_group} + \n tanneal_group: #{@tanneal_group}"
		end
	end


=begin
	A set of clusters of pcr_operations.
	the clusters will be made by the proximity of extension
	time, so that multiple pcr_operations can be optimally
	put into the same pcr reaction if they have similar enough
	extension time 
	
	representation invariant

	initial size of pcr_operations == clusters.map { members }.flatten.size
    Set(pcr_operations) == Set(clusters.map { members }.flatten)

	pcr operations belong to exactly 1 cluster


	
=end
	class ExtensionClusterGraph
		include GradientPcrHelpers

		attr_reader :size, :initial_size, :adjacency_list

		# Use a list of pcr_operations to create a set of singleton clusters
		# ready for combining into larger clusters based on similarity of extension time
		#
		# @param opts [Hash]  arguments hash
		# @option pcr_operations [Array<PcrOperation>]  list of pcr_operations to be clustered 
		# @option thermocycler_quantity
		# @option thermocycler_rows [Integer]
		# @option thermocycler_columns [Integer]
		def initialize(opts = {}) #TODO initialize with fields thermocycler_quantity, thermocycler_rows, thermocycler_columns
			pcr_operations 				= opts[:pcr_operations]
			@thermocycler_quantity 		= opts[:thermocycler_quantity]
			@thermocycler_rows  		= opts[:thermocycler_rows]
			@thermocycler_columns  		= opts[:thermocycler_columns]
			@thermocycler_temp_range 	= opts[:thermocycler_temp_range]
			@size = pcr_operations.size
			@initial_size = @size
			@final_cluster = ExtensionCluster.singleton_cluster(pcr_operations.first) if pcr_operations.one?

			# build complete graph (as adjacency matrix) with edges between 
			# clusters as the absolute difference between those clusters' extension times 
			initial_graph = build_dissimilarity_matrix(pcr_operations) do |a, b| #O(n^2)
				distance_func(ExtensionCluster.singleton_cluster(a),ExtensionCluster.singleton_cluster(b)) 
			end

			# remove all edges except those needed for mst, and then represent this graph as 
			# a min heap of edges, with extension time difference as the priority value
			# and adding the operations to the list represented as singleton clusters
			singleton_clusters = pcr_operations.map { |pcr_op| ExtensionCluster.singleton_cluster(pcr_op) }
			@adjacency_list = build_mst_adjacency_list(initial_graph, singleton_clusters)  #O(n^2)
		end

		def combine_nearest_clusters
			distance = @adjacency_list.min_priority
			pair = @adjacency_list.delete_min_return_key #logn
			cluster_a, cluster_b = pair.to_a
			@size -= 1
			cluster_ab = cluster_a.combine_with(cluster_b)


			# go through adjacency list updating pairs and distances to reflect this new merge
			# lots of edge cases here ex:
			# c - a, c - b
			# after merge, c - ab, c - ab
			@adjacency_list.each do |pair, priority| #O(nLogn) or maybe O((Logn)^2) for whole loop
				assert(pair.size == 2)
				if pair.include?(cluster_a) || pair.include?(cluster_b)
					new_pair = Set.new(pair) #Priority queue probably uses hash code of the object, which is not retained for arrays on content change, so we cannot 'update this pair in the queue using its reference' 
					new_pair.delete?(cluster_a) || new_pair.delete?(cluster_b) 
					new_pair.add(cluster_ab)
					new_priority = distance_func(new_pair.to_a[0], new_pair.to_a[1])
					if @adjacency_list.has_key?(new_pair) #edgecase: merge will cause a duplicate pair
						assert(@adjacency_list[new_pair] == new_priority)
						remove_heap_element(@adjacency_list, pair)
						@size -= 1
					else
						replace_heap_element(@adjacency_list, pair, new_pair, priority, new_priority) #logn	
					end
				end
			end

			if @adjacency_list.empty?
				@final_cluster = cluster_ab
			end
		end



		def distance_func(cluster_a, cluster_b)
			if (cluster_a.size + cluster_b.size) > (@thermocycler_rows * @thermocycler_columns) && (TannealCluster.anneal_range(cluster_a, cluster_b) > @thermocycler_temp_range)
				# prevent combination if it would produce an anneal range or batch size that a single thermocycler cannot handle
				return Float::MAX
			else
				return (cluster_a.mean_extension - cluster_b.mean_extension).abs
			end
		end

		# decides whether or not further clustering is required
		#
		# @return [Boolean]  whether clustering has finished
		def threshhold_func force_combination_distance
			if @adjacency_list.empty?
				return true
			end

			if @size <= @thermocycler_quantity
				if @adjacency_list.min_priority < force_combination_distance
					false
				else
					true
				end
			else
				false
			end
		end


		def cluster_set
			clusters = Set.new
			clusters << @final_cluster if @final_cluster
			@adjacency_list.each do |cluster_tuple, priority|
				cluster_tuple.each do |cluster|
					clusters << cluster.get_containing_supercluster()
				end
			end
			clusters
		end

		def checkrep
			clusters = cluster_set()
			total_pcr_members = clusters.to_a.map { |c| c.members }.flatten.size
			assert(total_pcr_members == @initial_size)
		end

		def to_string 
			"thermocycler_quantity:" + @thermocycler_quantity.to_s + "\n" + "thermocycler_rows:" + @thermocycler_rows.to_s + "\n" + "thermocycler_columns:" + @thermocycler_columns.to_s + "\n" + "size:" + @size.to_s + "\n" + "initial_size:" + @initial_size.to_s
		end
	end

	# A cluster of PCR operations based on the
	# nearness of their extension times
	class ExtensionCluster
		include GradientPcrHelpers

		attr_reader :size, :min_extension, :max_extension, :mean_extension, :max_anneal, :min_anneal, :parent_clusters, :child_cluster
		attr_writer :child_cluster

		def initialize(opts)
			@size 	 = opts[:size]
			@min_extension 	 = opts[:min_extension]
			@max_extension 	 = opts[:max_extension]
			@mean_extension  = opts[:mean_extension]
			@max_anneal 	 = opts[:max_anneal]
			@min_anneal 	 = opts[:min_anneal]
			@parent_clusters = opts[:parent_clusters]
			@child_cluster   = opts[:child_cluster]
			@pcr_operation   = opts[:pcr_operation]
		end

		def self.singleton_cluster(pcr_operation)
			ext = pcr_operation.extension_time
			anneal = pcr_operation.anneal_temp
			ExtensionCluster.new(
					size: 			1, 
					min_extension: 	ext, 
					max_extension: 	ext, 
					mean_extension: ext,
					max_anneal: 	anneal,
					min_anneal: 	anneal,
					pcr_operation:  pcr_operation
				)
		end

		def combine_with(other)
			combined_size = self.size + other.size
			combined_min = min(self.min_extension, other.min_extension)
			combined_max = max(self.max_extension, other.max_extension)
			combined_mean = combine_means(self.size, other.size, self.mean_extension, other.mean_extension)
			super_cluster = ExtensionCluster.new(
					size: 			 combined_size, 
					min_extension: 	 combined_min, 
					max_extension: 	 combined_max, 
					mean_extension:  combined_mean,
					max_anneal: 	 max(self.max_anneal, other.max_anneal),
					min_anneal: 	 min(self.min_anneal, other.min_anneal),
					parent_clusters: [self,other]
				)
			self.child_cluster = super_cluster
			other.child_cluster = super_cluster

			super_cluster
		end

		# calculate members when needed
		# lazy approach, so we dont have to keep track of the member_list for each cluster 
		def members()
			if @parent_clusters.nil?
				return [@pcr_operation]
			else
				return @parent_clusters[0].members.concat(@parent_clusters[1].members)
			end
		end

		def get_containing_supercluster()
			if @child_cluster.nil?
				return self
			else
				return @child_cluster.get_containing_supercluster()
			end
		end

		def to_string()
			"size: #{@size} \n extension range: #{min_extension}-#{max_extension} \n anneal range: #{min_anneal}-#{max_anneal} \n"
		end
	end
end